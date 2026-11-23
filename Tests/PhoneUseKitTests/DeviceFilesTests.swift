import CryptoKit
import Foundation
import XCTest
@testable import PhoneUseKit

private func fileRow(_ name: String = "config.txt", directory: Bool = false, link: Bool = false, size: Int = 5) -> [String: Any] {
    ["name": name, "relativePath": name,
     "resources": ["isDirectory": directory, "isSymbolicLink": link, "isReadable": true],
     "metadata": ["size": size, "lastModDate": "2026-01-01T00:00:00.000Z"]]
}

private actor FileCommandProbe {
    var commands: [[String]] = []
    let bytes: Data
    let rows: [[String: Any]]
    let failCopy: Bool
    init(bytes: Data = Data("hello".utf8), rows: [[String: Any]] = [fileRow()], failCopy: Bool = false) {
        self.bytes = bytes; self.rows = rows; self.failCopy = failCopy
    }
    func run(_ args: [String], _ timeout: Int) throws -> [String: Any] {
        commands.append(args)
        if args.starts(with: ["device", "info", "files"]) { return ["files": rows] }
        if args.starts(with: ["device", "copy", "from"]), let position = args.firstIndex(of: "--destination") {
            try bytes.write(to: URL(fileURLWithPath: args[position + 1]))
            if failCopy { throw DeviceHubError.connectionClosed }
            return [:]
        }
        throw DeviceHubError.serviceFailed("Unexpected command")
    }
    nonisolated var service: DeviceFiles { DeviceFiles(identifier: "test-device", run: { try await self.run($0, $1) }) }
}

final class DeviceFilesTests: XCTestCase {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testNestedListingUsesRequestedDirectoryAndDoesNotConfuseLinksWithFolders() throws {
        let entries = try DeviceFiles.files(from: ["files": [fileRow(), fileRow("folder", directory: true),
                                                            fileRow("shortcut", directory: true, link: true)]], directory: "Library/Caches")
        XCTAssertEqual(entries.first?.path, "Library/Caches/folder")
        XCTAssertEqual(entries.first { $0.name == "config.txt" }?.size, 5)
        XCTAssertEqual(entries.first { $0.name == "shortcut" }?.kind, .symbolicLink)
        XCTAssertThrowsError(try DeviceFiles.files(from: [:], directory: "."))
        XCTAssertThrowsError(try DeviceFiles.files(from: ["files": [fileRow("../outside")]], directory: "."))
    }

    func testCanonicalPathsRejectAbsolutePathsAndTraversal() throws {
        XCTAssertEqual(try DeviceFiles.relativePath("./Library//Caches/"), "Library/Caches")
        XCTAssertEqual(try DeviceFiles.relativePath(""), ".")
        for path in ["/private/var", "../other", "Library/../other", "bad\0name"] {
            XCTAssertThrowsError(try DeviceFiles.relativePath(path))
        }
    }

    func testAppContainerAccessIsReadFromDeviceRatherThanGuessedFromSigning() async throws {
        let service = DeviceFiles(identifier: "one", run: { _, _ in
            ["apps": [["bundleIdentifier": "example.debug", "name": "Debug", "builtByDeveloper": true, "containerAccessible": false],
                      ["bundleIdentifier": "example.unknown", "name": "Unknown"]]]
        })
        let apps = try await service.apps()
        XCTAssertEqual(apps[0].containerAccessible, false)
        XCTAssertNil(apps[1].containerAccessible)
    }

    func testReadsActualTextAndCleansTemporaryCopy() async throws {
        let probe = FileCommandProbe(bytes: Data("hello 世界".utf8))
        let text = try await probe.service.readText(bundleID: "example.app", path: "Library/config.txt")
        XCTAssertEqual(text, "hello 世界")
        let commands = await probe.commands
        XCTAssertTrue(commands[0].contains("--no-recurse"))
        XCTAssertTrue(commands[0].contains("Library"))
        let copy = try XCTUnwrap(commands.last)
        let index = try XCTUnwrap(copy.firstIndex(of: "--destination"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: copy[index + 1]))
        XCTAssertTrue(copy.contains("Library/config.txt"))
    }

    func testRejectsDirectoriesLinksOversizedAndBinaryText() async throws {
        for row in [fileRow(directory: true), fileRow(link: true), fileRow(size: 65_537)] {
            let probe = FileCommandProbe(rows: [row])
            do { _ = try await probe.service.readText(bundleID: "example", path: "config.txt"); XCTFail("must reject") }
            catch {}
            let commands = await probe.commands
            XCTAssertEqual(commands.count, 1, "Never copy known unsupported entries")
        }
        for bytes in [Data([0, 1, 2]), Data(repeating: 65, count: 65_537)] {
            let probe = FileCommandProbe(bytes: bytes)
            do { _ = try await probe.service.readText(bundleID: "example", path: "config.txt"); XCTFail("must reject") }
            catch {}
        }
    }

    func testDownloadPublishesCompleteFileAndRefusesOverwrite() async throws {
        let folder = try temporaryDirectory(), probe = FileCommandProbe()
        let destination = folder.appendingPathComponent("result.txt")
        try await probe.service.download(bundleID: "example", path: "config.txt", to: destination)
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "hello")
        do { try await probe.service.download(bundleID: "example", path: "config.txt", to: destination); XCTFail("must not overwrite") }
        catch {}
        let commands = await probe.commands
        XCTAssertEqual(commands.count, 2)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), ["result.txt"])
    }

    func testFailedCopyLeavesNoPartialDestinationOrStagingFiles() async throws {
        let folder = try temporaryDirectory(), probe = FileCommandProbe(failCopy: true)
        do {
            try await probe.service.download(bundleID: "example", path: "config.txt", to: folder.appendingPathComponent("result.txt"))
            XCTFail("must fail")
        } catch {}
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty)
    }

    /// Opt-in read-only check: no app launch, device writes or UI input.
    func testConnectedDeviceSandboxRead() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let udid = environment["DEVICEHUB_SANDBOX_DEVICE"], let bundle = environment["DEVICEHUB_SANDBOX_APP"],
              let path = environment["DEVICEHUB_SANDBOX_FILE"] else {
            throw XCTSkip("Set DEVICEHUB_SANDBOX_DEVICE/APP/FILE for read-only device validation")
        }
        let device = try JSONDecoder().decode(DeviceSummary.self, from: JSONSerialization.data(withJSONObject: [
            "platform": udid.hasPrefix("android:") ? "android" : "ios",
            "udid": udid, "name": "Sandbox test", "connection": "usb", "state": "ready", "session": "closed",
        ]))
        let service = try DeviceFiles(device: device)
        let apps = try await service.apps()
        XCTAssertNotNil(apps.first { $0.bundleIdentifier == bundle })
        let entries = try await service.list(bundleID: bundle)
        let top = try XCTUnwrap(path.split(separator: "/").first)
        XCTAssertTrue(entries.contains { $0.name == String(top) })
        let destination = try temporaryDirectory().appendingPathComponent("download")
        try await service.download(bundleID: bundle, path: path, to: destination)
        if let expected = environment["DEVICEHUB_SANDBOX_SHA256"] {
            let data = try Data(contentsOf: destination, options: .mappedIfSafe)
            let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            XCTAssertEqual(digest, expected)
        } else {
            XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path))
        }
        if let text = try? String(contentsOf: destination, encoding: .utf8), text.utf8.count <= DeviceFiles.maximumTextBytes,
           !text.contains("\0") {
            let preview = try await service.readText(bundleID: bundle, path: path)
            XCTAssertEqual(preview, text)
        }
    }
}
