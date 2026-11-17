import Foundation

public struct SandboxApp: Codable, Hashable, Identifiable, Sendable {
    public var id: String { bundleIdentifier }
    public let bundleIdentifier: String
    public let name: String
    public let version: String?
    /// Unknown on older tools. Development signing alone does not imply access.
    public let containerAccessible: Bool?
}

public struct SandboxFile: Codable, Hashable, Identifiable, Sendable {
    public enum Kind: String, Codable, Sendable { case file, directory, symbolicLink }
    public var id: String { path }
    public let name: String
    /// Relative to the application's data container, never a device absolute path.
    public let path: String
    public let kind: Kind
    public let size: Int64?
    public let modified: String?
    public let readable: Bool?
}

/// Shared by the device panel and MCP. Does not require opening a screen/input session.
public protocol DeviceFileAccess: Sendable {
    func apps() async throws -> [SandboxApp]
    func list(bundleID: String, path: String) async throws -> [SandboxFile]
    func readText(bundleID: String, path: String) async throws -> String
    func download(bundleID: String, path: String, to destination: URL) async throws
}

/// Read-only app-container access using the same CoreDevice route as Xcode's device window.
/// A daemon-only pairing is insufficient: CoreDevice must also know this device.
public struct DeviceFiles: DeviceFileAccess {
    public static let maximumTextBytes = 65_536
    private let identifier: String
    private let run: @Sendable ([String], Int) async throws -> [String: Any]

    public init(device: DeviceSummary) throws {
        guard !device.isAndroid else {
            throw DeviceHubError.capabilityUnavailable("App sandbox browsing is currently available for iOS devices only")
        }
        guard device.isReady else { throw DeviceHubError.deviceNotReady(device.name) }
        self.init(identifier: device.deviceIdentifier, run: { try await DeviceCtl.run($0, timeout: $1) })
    }

    init(identifier: String, run: @escaping @Sendable ([String], Int) async throws -> [String: Any]) {
        self.identifier = identifier
        self.run = run
    }

    public func apps() async throws -> [SandboxApp] {
        let result = try await run(["device", "info", "apps", "--device", identifier], 30)
        guard let rows = result["apps"] as? [[String: Any]] else { throw malformed() }
        return try rows.map { row in
            guard let bundle = row["bundleIdentifier"] as? String, !bundle.isEmpty else { throw malformed() }
            return SandboxApp(bundleIdentifier: bundle, name: row["name"] as? String ?? bundle,
                              version: row["version"] as? String, containerAccessible: row["containerAccessible"] as? Bool)
        }.sorted { $0.name == $1.name ? $0.bundleIdentifier < $1.bundleIdentifier : $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    public func list(bundleID: String, path: String = ".") async throws -> [SandboxFile] {
        let path = try Self.relativePath(path)
        let arguments = try ["device", "info", "files"] + domain(bundleID)
            + ["--subdirectory", path, "--no-recurse"]
        let result: [String: Any]
        do { result = try await run(arguments, 30) }
        catch is CancellationError { throw CancellationError() }
        catch {
            throw DeviceHubError.serviceFailed("Cannot browse the sandbox of \(bundleID). Check list_apps containerAccessible, unlock the device, and confirm Xcode recognizes it. \(error)")
        }
        return try Self.files(from: result, directory: path)
    }

    static func files(from result: [String: Any], directory: String) throws -> [SandboxFile] {
        guard let rows = result["files"] as? [[String: Any]] else { throw malformed() }
        let directory = try relativePath(directory)
        return try rows.map { row in
            // devicectl reports relativePath relative to the requested directory, not the container.
            guard let name = row["name"] as? String, !name.isEmpty, name != ".", name != "..",
                  !name.contains("/"), !name.contains("\0"),
                  let resources = row["resources"] as? [String: Any],
                  let isDirectory = resources["isDirectory"] as? Bool else { throw malformed() }
            let metadata = row["metadata"] as? [String: Any] ?? [:]
            return SandboxFile(name: name, path: directory == "." ? name : directory + "/" + name,
                               kind: resources["isSymbolicLink"] as? Bool == true ? .symbolicLink : isDirectory ? .directory : .file,
                               size: (metadata["size"] as? NSNumber)?.int64Value,
                               modified: metadata["lastModDate"] as? String, readable: resources["isReadable"] as? Bool)
        }.sorted {
            if ($0.kind == .directory) != ($1.kind == .directory) { return $0.kind == .directory }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    /// Canonical container-relative paths. No shell expansion or traversal is performed.
    public static func relativePath(_ value: String) throws -> String {
        guard !value.hasPrefix("/"), !value.contains("\0") else {
            throw DeviceHubError.serviceFailed("Use a path relative to the app sandbox, such as Library/Preferences.")
        }
        let parts = value.split(separator: "/").map(String.init)
        guard !parts.contains("..") else { throw DeviceHubError.serviceFailed("Sandbox paths must not contain '..'.") }
        let clean = parts.filter { $0 != "." }.joined(separator: "/")
        return clean.isEmpty ? "." : clean
    }

    public func readText(bundleID: String, path: String) async throws -> String {
        let file = try await regularFile(bundleID: bundleID, path: path)
        guard let size = file.size, size >= 0, size <= Self.maximumTextBytes else {
            throw DeviceHubError.serviceFailed("Text preview is limited to 64 KiB. Download this file instead.")
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("phoneuse-preview-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let local = directory.appendingPathComponent("content")
        try await copy(bundleID: bundleID, path: file.path, to: local)
        let handle = try FileHandle(forReadingFrom: local)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: Self.maximumTextBytes + 1) ?? Data()
        guard data.count <= Self.maximumTextBytes else {
            throw DeviceHubError.serviceFailed("The file grew beyond the 64 KiB preview limit. Download it instead.")
        }
        guard !data.contains(0), let text = String(data: data, encoding: .utf8) else {
            throw DeviceHubError.serviceFailed("This file is not UTF-8 text. Download it to inspect its contents.")
        }
        return text
    }

    /// Copies a single regular file. Publishes only a complete copy and never replaces a local file.
    public func download(bundleID: String, path: String, to destination: URL) async throws {
        guard destination.isFileURL, destination.path.hasPrefix("/"), destination.lastPathComponent != "" else {
            throw DeviceHubError.serviceFailed("Choose an absolute local file destination.")
        }
        let manager = FileManager.default
        guard !manager.fileExists(atPath: destination.path) else {
            throw DeviceHubError.serviceFailed("The destination already exists. Choose a new filename.")
        }
        let file = try await regularFile(bundleID: bundleID, path: path)
        let staging = destination.deletingLastPathComponent().appendingPathComponent(".phoneuse-download-\(UUID().uuidString)")
        try manager.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? manager.removeItem(at: staging) }
        let local = staging.appendingPathComponent("content")
        try await copy(bundleID: bundleID, path: file.path, to: local)
        try Task.checkCancellation()
        try manager.moveItem(at: local, to: destination)
    }

    private func regularFile(bundleID: String, path: String) async throws -> SandboxFile {
        let path = try Self.relativePath(path)
        guard path != "." else { throw DeviceHubError.serviceFailed("Select a file, not the sandbox root.") }
        let parts = path.split(separator: "/")
        let parent = parts.dropLast().joined(separator: "/")
        guard let file = try await list(bundleID: bundleID, path: parent).first(where: { $0.path == path }) else {
            throw DeviceHubError.serviceFailed("The file no longer exists. Refresh the directory.")
        }
        guard file.kind == .file, file.readable != false else {
            throw DeviceHubError.serviceFailed("Only readable regular files can be previewed or downloaded; directories and symbolic links are unsupported.")
        }
        return file
    }

    private func copy(bundleID: String, path: String, to destination: URL) async throws {
        _ = try await run(["device", "copy", "from"] + domain(bundleID)
                         + ["--source", path, "--destination", destination.path], 120)
        let values = try destination.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw DeviceHubError.serviceFailed("The device did not return a regular file.")
        }
    }

    private func domain(_ bundleID: String) throws -> [String] {
        guard !bundleID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !bundleID.contains("\0") else {
            throw DeviceHubError.serviceFailed("An app bundle identifier is required.")
        }
        return ["--device", identifier, "--domain-type", "appDataContainer", "--domain-identifier", bundleID]
    }

    private static func malformed() -> DeviceHubError { .serviceFailed("Unexpected device file-service response. Update Xcode and retry.") }
    private func malformed() -> DeviceHubError { Self.malformed() }
}
