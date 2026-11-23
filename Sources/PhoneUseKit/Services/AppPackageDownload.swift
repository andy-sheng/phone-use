import Foundation

public enum AppPackageDownload {
    /// A direct download on the Mac. Query strings on signed build links are preserved.
    public static func url(_ input: String) throws -> URL {
        guard let url = URL(string: input), ["http", "https"].contains(url.scheme?.lowercased()),
              url.host?.isEmpty == false, url.user == nil, url.password == nil else {
            throw DeviceHubError.serviceFailed("Enter an HTTP or HTTPS download link.")
        }
        return url
    }

    static func withPackage<T>(from source: URL, for device: DeviceSummary,
                               install: (URL) async throws -> T) async throws -> T {
        let url = try self.url(source.absoluteString)
        let files = FileManager.default
        let directory = files.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try files.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? files.removeItem(at: directory) }

        let ext = device.isSimulator ? "zip" : device.appPackageExtension
        let archive = directory.appendingPathComponent("package." + ext)
        // curl streams to disk and also supports plain HTTP build servers without app-wide ATS exceptions.
        _ = try await HostCommand.run("/usr/bin/curl", [
            "--disable", "--globoff", "--fail", "--silent", "--show-error", "--location",
            "--proto", "=http,https", "--proto-redir", url.scheme?.lowercased() == "https" ? "=https" : "=http,https",
            "--connect-timeout", "30", "--max-time", "1800", "--max-filesize", "8589934592",
            "--output", archive.path, "--url", url.absoluteString,
        ])
        try Task.checkCancellation()
        let package: URL
        if device.isSimulator {
            package = try await simulatorApp(in: archive, directory: directory)
        } else {
            // Download endpoints often have no filename. Check the package itself before contacting the device.
            let marker = device.isAndroid ? "AndroidManifest.xml" : "Payload/*.app/Info.plist"
            do {
                _ = try await HostCommand.run("/usr/bin/unzip", ["-Z1", archive.path, marker])
            } catch DeviceHubError.serviceFailed {
                throw DeviceHubError.serviceFailed("The download is not a \(device.appPackageDescription). Use a direct package link.")
            }
            package = archive
        }
        try Task.checkCancellation()
        return try await install(package)
    }

    static func simulatorApp(in archive: URL, directory: URL) async throws -> URL {
        // Inspect ZIP size before expansion. zipinfo -t reports the count and uncompressed bytes.
        let totals = try await HostCommand.run("/usr/bin/unzip", ["-Zt", archive.path], environment: ["LC_ALL": "C"])
        let fields = String(decoding: totals, as: UTF8.self).split(whereSeparator: \.isWhitespace)
        guard fields.count >= 4, let entries = Int(fields[0]), (1...200_000).contains(entries),
              let bytes = Int64(fields[2]), (1...16_000_000_000).contains(bytes) else {
            throw DeviceHubError.serviceFailed("The simulator ZIP is invalid or too large to expand.")
        }
        let files = FileManager.default
        let root = directory.appendingPathComponent("unpacked")
        try files.createDirectory(at: root, withIntermediateDirectories: false)
        // bsdtar's default secure extraction rejects traversal and writes through symlinks.
        _ = try await HostCommand.run("/usr/bin/tar", [
            "-xf", archive.path, "-C", root.path, "--no-same-owner", "--no-same-permissions",
            "--no-xattrs", "--no-acls", "--no-fflags", "--no-mac-metadata",
        ])
        let apps = try files.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension.lowercased() == "app" }
        guard apps.count == 1, let app = apps.first else {
            throw DeviceHubError.serviceFailed("Provide a ZIP containing one simulator .app at its top level.")
        }
        let values = try app.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
        guard values.isDirectory == true, values.isSymbolicLink == false else {
            throw DeviceHubError.serviceFailed("The .app in the ZIP must be a directory.")
        }
        // simctl subsequently reads the bundle. Internal framework links may resolve only inside it.
        let prefix = app.resolvingSymlinksInPath().path + "/"
        var traversalError: Error?
        guard let members = files.enumerator(at: app, includingPropertiesForKeys: [.isSymbolicLinkKey],
                                              errorHandler: { _, error in traversalError = error; return false }) else {
            throw DeviceHubError.serviceFailed("Cannot read the extracted .app.")
        }
        for case let member as URL in members {
            if try member.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true,
               !member.resolvingSymlinksInPath().path.hasPrefix(prefix) {
                throw DeviceHubError.serviceFailed("The simulator .app contains a link outside its bundle.")
            }
        }
        if let traversalError { throw traversalError }
        return app
    }
}
