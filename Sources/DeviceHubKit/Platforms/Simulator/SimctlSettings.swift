import Foundation

/// Simulator settings through `xcrun simctl`, for an Xcode whose `devicectl` has no device settings.
struct SimctlSettings: DeviceSettingsBackend {
    typealias Settings = DeviceSettings

    /// The simulator's UDID.
    let identifier: String
    var source: Settings.Source { .simctl }
    var canRecord: Bool { SimulatorTools.developerDirectory() != nil }

    private func simctl(_ arguments: [String]) async throws -> String {
        guard let developer = SimulatorTools.developerDirectory() else {
            throw DeviceHubError.serviceFailed("Xcode is required to change simulator settings")
        }
        return try await SimulatorTools.simctl(arguments, developerDirectory: developer)
    }

    func appearance() async throws -> Settings.Appearance {
        async let style = simctl(["ui", identifier, "appearance"])
        async let contrast = simctl(["ui", identifier, "increase_contrast"])
        async let size = simctl(["ui", identifier, "content_size"])
        var appearance = Settings.Appearance()
        // simctl answers "unsupported" or "unknown" for settings the runtime does not offer.
        appearance.style = Settings.InterfaceStyle(rawValue: (try? await style) ?? "")
        switch try? await contrast {
        case "enabled"?: appearance.increaseContrast = true
        case "disabled"?: appearance.increaseContrast = false
        default: break
        }
        appearance.textSize = Settings.TextSize(rawValue: (try? await size) ?? "")
        return appearance
    }

    func apply(_ change: Settings.AppearanceChange) async throws {
        switch change {
        case .style(let style): try await simctl(["ui", identifier, "appearance", style.rawValue])
        case .increaseContrast(let on): try await simctl(["ui", identifier, "increase_contrast", on ? "enabled" : "disabled"])
        case .textSize(let size): try await simctl(["ui", identifier, "content_size", size.rawValue])
        default: throw Self.unsupported("\(change)")
        }
    }

    func locations() async throws -> [Settings.Location] {
        Settings.Location.presets
    }

    func simulate(_ location: Settings.Location?) async throws {
        switch location?.kind {
        case .coordinate(let latitude, let longitude)?:
            try await simctl(["location", identifier, "set", "\(latitude),\(longitude)"])
        case .scenario?:
            throw Self.unsupported("Location scenarios")
        case nil:
            try await simctl(["location", identifier, "clear"])
        }
    }

    func startRecording(to destination: URL) throws -> ScreenRecording {
        guard let developer = SimulatorTools.developerDirectory() else { throw Self.unsupported("Screen recording") }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["simctl", "io", identifier, "recordVideo", "--codec=h264", "--force", destination.path]
        process.environment = ProcessInfo.processInfo.environment.merging(["DEVELOPER_DIR": developer]) { $1 }
        process.standardInput = FileHandle.nullDevice
        return try ScreenRecording(process: process, destination: destination)
    }
}
