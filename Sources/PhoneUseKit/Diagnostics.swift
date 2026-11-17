import CryptoKit
import Foundation

/// File diagnostics never use stdout: CLI/MCP/bridge stdout belongs to their protocols.
public enum Diagnostics {
    private static let lock = NSLock()
    private static let timestamp: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private static var writers: [String: DiagnosticWriter] = [:]
    public static let processSession = UUID().uuidString

    public static func record(_ event: String, _ fields: [String: String] = [:]) {
        lock.lock()
        defer { lock.unlock() }
        let directory = PhoneUseConfiguration.current.logDirectory
        let key = directory.path
        if writers[key] == nil {
            writers[key] = DiagnosticWriter(directory: directory, name: "process-\(ProcessInfo.processInfo.processIdentifier)-\(processSession)")
        }
        var entry = fields
        entry["event"] = event
        entry["time"] = timestamp.string(from: Date())
        entry["pid"] = String(ProcessInfo.processInfo.processIdentifier)
        entry["process"] = ProcessInfo.processInfo.processName
        entry["session"] = processSession
        entry["run"] = ProcessInfo.processInfo.environment["DEVICEHUB_RUN_ID"] ?? fields["run"]
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        entry = entry.mapValues { String($0.replacingOccurrences(of: home, with: "~").prefix(8192)) }
        writers[key]?.append(entry)
    }

    public static func deviceID(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
    }

    public static func startup() {
        record("process.start", metadata)
    }

    public static func output(_ data: Data) {
        // A traceback or burst of worker output may exceed one log field. Keep all chunks.
        var text = String(decoding: data, as: UTF8.self)[...]
        while !text.isEmpty {
            let end = text.index(text.startIndex, offsetBy: min(4000, text.count))
            record("daemon.output", ["text": String(text[..<end])])
            text = text[end...]
        }
    }

    public static var metadata: [String: String] {
        ["app": PhoneUseConfiguration.current.displayName,
         "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development",
         "build": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "development",
         "os": ProcessInfo.processInfo.operatingSystemVersionString,
         "timezone": TimeZone.current.identifier]
    }

    public static func elapsed(since start: TimeInterval) -> String {
        String(format: "%.0f", (ProcessInfo.processInfo.systemUptime - start) * 1000)
    }

    static func operation<T>(_ event: String, _ fields: [String: String] = [:],
                             body: () async throws -> T) async rethrows -> T {
        let start = ProcessInfo.processInfo.systemUptime
        var context = fields
        context["operation"] = UUID().uuidString
        record(event + ".begin", context)
        do {
            let result = try await body()
            context["elapsed_ms"] = elapsed(since: start)
            record(event + ".ok", context)
            return result
        } catch {
            context["elapsed_ms"] = elapsed(since: start)
            context["error"] = String(describing: error)
            record(event + ".failed", context)
            throw error
        }
    }
}

/// Each process owns a unique file, so helpers cannot race to rotate another process's writer.
final class DiagnosticWriter {
    let directory: URL
    let file: URL
    let maximumBytes: Int
    private var warned = false

    init(directory: URL, name: String, maximumBytes: Int = 2 * 1024 * 1024) {
        self.directory = directory
        file = directory.appendingPathComponent(name + ".jsonl")
        self.maximumBytes = maximumBytes
    }

    func append(_ entry: [String: String]) {
        do {
            let manager = FileManager.default
            try manager.createDirectory(at: directory, withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: 0o700])
            var data = try JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys])
            data.append(0x0A)
            let size = (try? manager.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.intValue ?? 0
            if size > 0, size + data.count > maximumBytes {
                let previous = file.appendingPathExtension("1")
                if manager.fileExists(atPath: previous.path) { try manager.removeItem(at: previous) }
                try manager.moveItem(at: file, to: previous)
            }
            if !manager.fileExists(atPath: file.path) {
                guard manager.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                    throw CocoaError(.fileWriteUnknown)
                }
                // Keep at most 40 files (80 MiB), removing only our own diagnostic file family.
                let files = try manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])
                    .filter { $0.lastPathComponent.hasPrefix("process-") && ($0.pathExtension == "jsonl" || $0.lastPathComponent.hasSuffix(".jsonl.1")) }
                    .sorted { Self.modified($0) > Self.modified($1) }
                for old in files.dropFirst(40) where old != file { try? manager.removeItem(at: old) }
            }
            let handle = try FileHandle(forWritingTo: file)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } catch {
            if !warned {
                warned = true
                FileHandle.standardError.write(Data("Diagnostic log unavailable: \(error)\n".utf8))
            }
        }
    }

    static func modified(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }
}

public enum DiagnosticBundle {
    public static func archive(to destination: URL, configuration: PhoneUseConfiguration,
                               runDirectories: [URL] = [], metadata: [String: String]) throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let folder = temporary.appendingPathComponent("Diagnostics")
        try collect(at: folder, configuration: configuration, runDirectories: runDirectories, metadata: metadata)
        let archive = temporary.appendingPathComponent("diagnostics.zip")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-c", "-k", "--keepParent", folder.path, archive.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw CocoaError(.fileWriteUnknown) }
        // Do not overwrite the user's chosen file until collection and compression succeed.
        if FileManager.default.fileExists(atPath: destination.path) {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: archive)
        } else { try FileManager.default.moveItem(at: archive, to: destination) }
    }

    /// Copies a bounded tail of text logs only; never copies pairing records, images or plugins.
    /// Additional run folders are supplied by the owning app, not discovered by the framework.
    public static func collect(at destination: URL, configuration: PhoneUseConfiguration,
                               runDirectories: [URL] = [], metadata: [String: String]) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: destination, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var copied: [String] = []
        var skipped: [String] = []
        let allowedRuns = ["runtime.log", "events.jsonl", "maa.log", "bridge.jsonl", "bridge.jsonl.1"]
        func copy(_ source: URL, relative: String) {
            do {
                let values = try source.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
                guard values.isRegularFile == true, values.isSymbolicLink != true else { return }
                let handle = try FileHandle(forReadingFrom: source)
                defer { try? handle.close() }
                let size = values.fileSize ?? 0
                let limit = 2 * 1024 * 1024
                if size > limit { try handle.seek(toOffset: UInt64(size - limit)) }
                var data = try handle.read(upToCount: limit) ?? Data()
                if size > limit, let newline = data.firstIndex(of: 10) { data.removeSubrange(...newline) }
                let target = destination.appendingPathComponent(relative)
                try manager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: target)
                copied.append(relative + (size > limit ? " (last 2 MiB)" : ""))
            } catch { skipped.append(relative + ": " + String(describing: error)) }
        }
        let logs = (try? manager.contentsOfDirectory(at: configuration.logDirectory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for file in logs.filter({ $0.lastPathComponent.hasPrefix("process-") && ($0.pathExtension == "jsonl" || $0.lastPathComponent.hasSuffix(".jsonl.1")) })
            .sorted(by: { DiagnosticWriter.modified($0) > DiagnosticWriter.modified($1) }).prefix(40) {
            copy(file, relative: "logs/" + file.lastPathComponent)
        }
        for (index, directory) in runDirectories.prefix(3).enumerated() {
            guard (try? directory.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == false else { continue }
            for name in allowedRuns {
                let source = directory.appendingPathComponent(name)
                if manager.fileExists(atPath: source.path) { copy(source, relative: "runs/\(index)-\(directory.lastPathComponent)/\(name)") }
            }
        }
        let manifest: [String: Any] = ["metadata": metadata, "created": ISO8601DateFormatter().string(from: Date()),
                                       "files": copied, "skipped": skipped,
                                       "note": "Text logs may contain device names, network addresses and plugin messages. Review before sharing. Images, pairing records and task files are excluded."]
        try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
            .write(to: destination.appendingPathComponent("manifest.json"))
    }
}
