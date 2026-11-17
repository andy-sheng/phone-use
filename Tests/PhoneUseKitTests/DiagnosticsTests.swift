import Foundation
import XCTest
@testable import PhoneUseKit

final class DiagnosticsTests: XCTestCase {
    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    func testRotationKeepsLatestFailureAndPreviousRequestWithoutShutdown() throws {
        let directory = try temporaryDirectory()
        let writer = DiagnosticWriter(directory: directory, name: "process-test", maximumBytes: 160)
        writer.append(["event": "request.begin", "padding": String(repeating: "x", count: 100)])
        writer.append(["event": "request.failed", "error": "timeout"])
        let latest = try JSONSerialization.jsonObject(with: Data(contentsOf: writer.file)) as? [String: String]
        XCTAssertEqual(latest?["error"], "timeout")
        let previous = try String(contentsOf: writer.file.appendingPathExtension("1"), encoding: .utf8)
        XCTAssertTrue(previous.contains("request.begin"))
        let permissions = try FileManager.default.attributesOfItem(atPath: writer.file.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o600)
    }

    func testExportIncludesBoundedLogsButExcludesImagesSecretsAndSymlinks() throws {
        let root = try temporaryDirectory()
        let logs = root.appendingPathComponent("logs")
        let run = root.appendingPathComponent("run-id")
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: run, withIntermediateDirectories: true)
        let writer = DiagnosticWriter(directory: logs, name: "process-test")
        writer.append(["event": "daemon.output", "text": "worker failure"])
        try Data("pairing secret".utf8).write(to: logs.appendingPathComponent("pairing.json"))
        try Data("private image".utf8).write(to: run.appendingPathComponent("final.png"))
        try Data("private task".utf8).write(to: run.appendingPathComponent("task.json"))
        let large = String(repeating: "old entry\n", count: 250_000) + "latest timeout\n"
        try Data(large.utf8).write(to: run.appendingPathComponent("runtime.log"))
        try FileManager.default.createSymbolicLink(at: run.appendingPathComponent("events.jsonl"),
                                                  withDestinationURL: logs.appendingPathComponent("pairing.json"))
        let destination = root.appendingPathComponent("export")
        let config = PhoneUseConfiguration(supportDirectory: root, logDirectory: logs, displayName: "Fixture")
        try DiagnosticBundle.collect(at: destination, configuration: config, runDirectories: [run], metadata: ["version": "test"])
        let exported = destination.appendingPathComponent("runs/0-run-id/runtime.log")
        let data = try Data(contentsOf: exported)
        XCTAssertLessThanOrEqual(data.count, 2 * 1024 * 1024)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).hasSuffix("latest timeout\n"))
        let files = FileManager.default.enumerator(atPath: destination.path)!.allObjects as! [String]
        XCTAssertTrue(files.contains("logs/process-test.jsonl"))
        XCTAssertFalse(files.contains { $0.contains("pairing") || $0.contains("final.png") || $0.contains("task.json") || $0.contains("events.jsonl") })
        let manifest = try String(contentsOf: destination.appendingPathComponent("manifest.json"), encoding: .utf8)
        XCTAssertTrue(manifest.contains("last 2 MiB"))
    }

    func testZIPCanBeExportedOverAnExistingDestinationAndReadBack() throws {
        let root = try temporaryDirectory()
        let destination = root.appendingPathComponent("diagnostics.zip")
        try Data("previous export".utf8).write(to: destination)
        let config = PhoneUseConfiguration(supportDirectory: root, logDirectory: root.appendingPathComponent("logs"), displayName: "Test")
        DiagnosticWriter(directory: config.logDirectory, name: "process-zip").append(["event": "screenshot.failed"])
        try DiagnosticBundle.archive(to: destination, configuration: config, metadata: ["version": "test"])
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-p", destination.path, "Diagnostics/logs/process-zip.jsonl"]
        process.standardOutput = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        let record = try JSONSerialization.jsonObject(with: data) as? [String: String]
        XCTAssertEqual(record?["event"], "screenshot.failed")
    }
}
