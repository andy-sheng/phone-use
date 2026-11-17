import Foundation

/// Device settings through Xcode's `devicectl`, for iPhone, iPad and simulators alike.
struct DeviceCtlSettings: DeviceSettingsBackend {
    typealias Settings = DeviceSettings

    let identifier: String
    var canRecord = false
    var source: Settings.Source { .xcode }

    static func supportsRecording(_ details: [String: Any]) -> Bool {
        (details["capabilities"] as? [[String: Any]] ?? []).contains {
            $0["featureIdentifier"] as? String == "com.apple.coredevice.feature.screenrecording"
        }
    }

    func appearance() async throws -> Settings.Appearance {
        try Self.appearance(from: try await DeviceCtl.run(["device", "info", "appearance", "--device", identifier]))
    }

    func apply(_ change: Settings.AppearanceChange) async throws {
        _ = try await DeviceCtl.run(["device", "settings", "appearance", "--device", identifier] + Self.arguments(for: change))
    }

    static func arguments(for change: Settings.AppearanceChange) -> [String] {
        func onOff(_ value: Bool) -> String { value ? "on" : "off" }
        switch change {
        case .style(let style): return ["--mode", style.rawValue]
        case .tintedLiquidGlass(let tinted): return ["--look-and-feel", tinted ? "tinted" : "clear"]
        case .liquidGlassOpacity(let value):
            return ["--liquid-glass-opacity", String(format: "%.2f", min(max(value, 0), 1))]
        case .colorFilter(let filter?): return ["--color-filter", "on", "--color-filter-type", filter.rawValue]
        case .colorFilter(nil): return ["--color-filter", "off"]
        case .textSize(let size):
            return (size.isAccessibilitySize ? ["--larger-accessibility-sizes", "on"] : []) + ["--text-size", size.rawValue]
        case .increaseContrast(let on): return ["--increase-contrast", onOff(on)]
        case .reduceMotion(let on): return ["--reduce-motion", onOff(on)]
        case .reduceTransparency(let on): return ["--reduce-transparency", onOff(on)]
        case .showBorders(let on): return ["--show-borders", onOff(on)]
        }
    }

    static func appearance(from result: [String: Any]) throws -> Settings.Appearance {
        func enabled(_ key: String) -> Bool {
            if let flag = result[key] as? Bool { return flag }
            return (result[key] as? [String: Any])?["enabled"] as? Bool ?? false
        }
        let filter = result["colorFilter"] as? [String: Any]
        let filterName = (filter?["filterType"] as? [String: Any])?["name"] as? String
        var appearance = Settings.Appearance()
        appearance.style = (result["userInterfaceStyle"] as? String).flatMap(Settings.InterfaceStyle.init(rawValue:))
        appearance.lookAndFeel = result["lookAndFeel"] as? String
        appearance.supportedLooksAndFeels = result["supportedLooksAndFeels"] as? [String] ?? []
        appearance.liquidGlassOpacity = (result["liquidGlassOpacity"] as? NSNumber)?.doubleValue
        appearance.supportedColorFilters = Settings.ColorFilter.allCases
        if filter?["enabled"] as? Bool == true {
            appearance.colorFilter = filterName.flatMap { Settings.ColorFilter(rawValue: $0.lowercased()) } ?? .grayscale
        }
        appearance.textSize = (result["textSize"] as? String).flatMap(Settings.TextSize.init(reportedName:))
        appearance.increaseContrast = enabled("increaseContrast")
        appearance.reduceMotion = enabled("reduceMotion")
        appearance.reduceTransparency = enabled("reduceTransparency")
        appearance.showBorders = enabled("showBorders")
        return appearance
    }

    func voiceOver() async throws -> Bool {
        try await DeviceCtl.run(["device", "info", "voiceover", "--device", identifier])["enabled"] as? Bool ?? false
    }

    func setVoiceOver(_ enabled: Bool) async throws {
        _ = try await DeviceCtl.run(["device", "settings", "voiceover", "--device", identifier,
                                     enabled ? "--enable" : "--disable"])
    }

    func audio() async throws -> Settings.Audio {
        let result = try await DeviceCtl.run(["device", "info", "audio", "--device", identifier])
        return Settings.Audio(volume: (result["volume"] as? NSNumber)?.intValue,
                              output: Self.route(result["audioOutputDevice"]),
                              input: Self.route(result["audioInputDevice"]))
    }

    /// A pinned route is reported as `{"device": {"_0": "<uid>"}}`.
    static func route(_ reported: Any?) -> Settings.AudioRoute {
        if let device = (reported as? [String: Any])?["device"] as? [String: Any],
           let uid = device.values.first as? String {
            return .device(uid)
        }
        return .systemDefault
    }

    func setAudio(volume: Int?, output: Settings.AudioRoute?, input: Settings.AudioRoute?) async throws {
        func argument(_ route: Settings.AudioRoute) -> String {
            switch route {
            case .systemDefault: "systemDefault"
            case .device(let uid): uid
            }
        }
        var arguments = ["device", "settings", "audio", "--device", identifier]
        if let volume { arguments += ["--volume", String(min(max(volume, 0), 100))] }
        if let output { arguments += ["--output-device", argument(output)] }
        if let input { arguments += ["--input-device", argument(input)] }
        _ = try await DeviceCtl.run(arguments)
    }

    func locations() async throws -> [Settings.Location] {
        let result = try await DeviceCtl.run(["device", "simulate", "location", "list", "--device", identifier])
        let scenarios = (result["availableScenarios"] as? [[String: Any]] ?? []).compactMap { scenario -> Settings.Location? in
            guard let name = scenario["name"] as? String else { return nil }
            return Settings.Location(name: scenario["localizedName"] as? String ?? name, kind: .scenario(name))
        }
        return scenarios.isEmpty ? Settings.Location.presets : scenarios
    }

    func simulate(_ location: Settings.Location?) async throws {
        var arguments = ["device", "simulate", "location"]
        switch location?.kind {
        case .scenario(let name)?: arguments += ["scenario", "--device", identifier, name]
        case .coordinate(let latitude, let longitude)?:
            // Attached, so a negative value is not taken for an option.
            arguments += ["coordinate", "--device", identifier, "--latitude=\(latitude)", "--longitude=\(longitude)"]
        case nil: arguments += ["clear", "--device", identifier]
        }
        _ = try await DeviceCtl.run(arguments)
    }

    func startRecording(to destination: URL) throws -> ScreenRecording {
        guard canRecord else { throw Self.unsupported("Screen recording") }
        return try ScreenRecording(process: DeviceCtl.process([
            "device", "capture", "screen-record", "--device", identifier,
            "--destination", destination.path, "--quiet",
        ]), destination: destination)
    }
}

/// Runs Xcode's `devicectl` and returns its JSON `result`.
enum DeviceCtl {
    private static let bundled = "/Library/Developer/PrivateFrameworks/CoreDevice.framework/Resources/bin/devicectl"

    /// Whether this Mac's `devicectl` can change device settings, which first shipped with Xcode 27.
    static var offersDeviceSettings: Bool {
        get async { await Probe.shared.offersDeviceSettings() }
    }

    private actor Probe {
        static let shared = Probe()
        private var result: Bool?

        func offersDeviceSettings() async -> Bool {
            if let result { return result }
            // Older tools print the parent command's help for an unknown subcommand.
            let help = (try? await DeviceCtl.output(["help", "device", "settings", "appearance"])) ?? ""
            let offered = help.contains("--reduce-motion")
            result = offered
            return offered
        }
    }

    static func process(_ arguments: [String]) throws -> Process {
        let process = Process()
        if FileManager.default.isExecutableFile(atPath: bundled) {
            process.executableURL = URL(fileURLWithPath: bundled)
            process.arguments = arguments
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
            process.arguments = ["devicectl"] + arguments
        }
        process.standardInput = FileHandle.nullDevice
        return process
    }

    /// The command's standard output, whatever its exit status.
    static func output(_ arguments: [String]) async throws -> String {
        let process = try process(arguments)
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        let finished = ProcessTermination(process)
        try process.run()
        let data = await Task.detached { output.fileHandleForReading.readDataToEndOfFile() }.value
        _ = await finished.wait()
        try Task.checkCancellation()
        return String(decoding: data, as: UTF8.self)
    }

    static func run(_ arguments: [String], timeout: Int = 30) async throws -> [String: Any] {
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("devicectl-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: output) }
        let process = try process(arguments + ["--quiet", "--timeout", String(timeout), "--json-output", output.path])
        let errors = Pipe()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errors
        let finished = ProcessTermination(process)
        try process.run()
        let message = await Task.detached { errors.fileHandleForReading.readDataToEndOfFile() }.value
        let status = await finished.wait()
        try Task.checkCancellation()
        let document = (try? Data(contentsOf: output))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        if status == 0, let result = document?["result"] as? [String: Any] {
            return result
        }
        throw DeviceHubError.serviceFailed(failure(in: document) ?? {
            let detail = String(decoding: message, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            return detail.isEmpty ? "devicectl \(arguments.prefix(3).joined(separator: " ")) failed" : detail
        }())
    }

    /// The localized description in a `devicectl` error document.
    static func failure(in document: [String: Any]?) -> String? {
        guard let info = (document?["error"] as? [String: Any])?["userInfo"] as? [String: Any],
              let description = info["NSLocalizedDescription"] else { return nil }
        return (description as? [String: Any])?["string"] as? String ?? description as? String
    }
}
