import Foundation
import XCTest
import PhoneUseKit
@testable import PhoneUseUI

private actor SandboxProbe: DeviceFileAccess, SandboxVolumeAccess {
    var waiting = false
    var continuation: CheckedContinuation<SandboxMount, Error>?
    let app: SandboxApp
    let volume: SandboxMount
    var ejections = 0
    init() throws {
        app = try JSONDecoder().decode(SandboxApp.self, from: Data(#"{"bundleIdentifier":"example.app","name":"Example","containerAccessible":true}"#.utf8))
        volume = try JSONDecoder().decode(SandboxMount.self, from: Data(#"{"id":"token","bundleID":"example.app","path":"/tmp/example"}"#.utf8))
    }
    func apps() async throws -> [SandboxApp] { [app] }
    func list(bundleID: String, path: String) async throws -> [SandboxFile] { [] }
    func readText(bundleID: String, path: String) async throws -> String { "text" }
    func download(bundleID: String, path: String, to destination: URL) async throws {}
    func mounts() async throws -> [SandboxMount] { [] }
    func mount(_ app: SandboxApp) async throws -> SandboxMount {
        try await withCheckedThrowingContinuation { continuation = $0; waiting = true }
    }
    func unmount(_ volume: SandboxMount) async throws { ejections += 1 }
    func finish(fail: Bool = false) {
        if fail { continuation?.resume(throwing: DeviceHubError.connectionClosed) }
        else { continuation?.resume(returning: volume) }
        continuation = nil; waiting = false
    }
}

@MainActor
final class DeviceFilesModelTests: XCTestCase {
    private func device(_ id: String) throws -> DeviceSummary {
        try JSONDecoder().decode(DeviceSummary.self, from: JSONSerialization.data(withJSONObject: [
            "udid": id, "name": id, "connection": "usb", "state": "ready", "session": "closed",
        ]))
    }
    private func waitForMount(_ probe: SandboxProbe) async throws {
        for _ in 0..<100 {
            if await probe.waiting { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Request did not start")
    }

    func testMissingIconUsesPlaceholderAndRetriesOnlyOnRefresh() async throws {
        let probe = try SandboxProbe()
        var requests = 0
        let model = DeviceFilesModel(makeFiles: { _ in probe }, makeVolumes: { _ in probe }, fetchIcon: { _, _ in
            requests += 1
            return nil
        })
        await model.load(try device("one"))
        let app = try XCTUnwrap(model.apps.first)
        await model.loadIcon(app)
        await model.loadIcon(app)
        XCTAssertEqual(requests, 1)
        XCTAssertTrue(model.icons.isEmpty)
        XCTAssertNil(model.error)
        await model.load(try device("one"))
        await model.loadIcon(app)
        XCTAssertEqual(requests, 2)
    }

    func testClosingPickerDoesNotOpenFinderForLateMount() async throws {
        let probe = try SandboxProbe()
        var opened = [URL]()
        let model = DeviceFilesModel(makeFiles: { _ in probe }, makeVolumes: { _ in probe }, openFinder: { opened.append($0); return true })
        await model.load(try device("one"))
        model.selection = model.apps.first?.id
        let mount = Task { await model.open() }
        try await waitForMount(probe)
        model.stop()
        await probe.finish()
        await mount.value
        XCTAssertTrue(opened.isEmpty)
        XCTAssertFalse(model.isBusy)
        // A successful volume remains owned by the daemon after the picker closes.
        let ejections = await probe.ejections
        XCTAssertEqual(ejections, 0)
    }

    func testDeviceChangeDiscardsLateMountError() async throws {
        let probe = try SandboxProbe()
        let model = DeviceFilesModel(makeFiles: { _ in probe }, makeVolumes: { _ in probe }, openFinder: { _ in false })
        await model.load(try device("one"))
        model.selection = model.apps.first?.id
        let mount = Task { await model.open() }
        try await waitForMount(probe)
        await model.load(try device("two"))
        await probe.finish(fail: true)
        await mount.value
        XCTAssertNil(model.error)
        XCTAssertNil(model.selection)
        XCTAssertFalse(model.isBusy)
    }

    func testSuccessfulMountOpensFinderAndCanEject() async throws {
        let probe = try SandboxProbe()
        var opened = [URL]()
        let model = DeviceFilesModel(makeFiles: { _ in probe }, makeVolumes: { _ in probe }, openFinder: { opened.append($0); return true })
        await model.load(try device("one"))
        model.selection = model.apps.first?.id
        let mount = Task { await model.open() }
        try await waitForMount(probe)
        await probe.finish()
        await mount.value
        XCTAssertEqual(opened.map(\.path), ["/tmp/example"])
        XCTAssertNotNil(model.selectedMount)
        await model.eject()
        XCTAssertNil(model.selectedMount)
        XCTAssertNil(model.error)
        let ejections = await probe.ejections
        XCTAssertEqual(ejections, 1)
    }
}
