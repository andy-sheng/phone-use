import Foundation

/// Device settings over the daemon's own tunnel, for iPhone and iPad when Xcode's `devicectl` is
/// unavailable: the accessibility audit service (as used by Accessibility Inspector) and DVT
/// location simulation. It offers no interface style, Liquid Glass, VoiceOver, audio or recording.
/// The device keeps these changes only while the daemon's worker holds its channels open, so they
/// revert when the device is closed.
struct AccessibilityAuditSettings: DeviceSettingsBackend {
    typealias Settings = DeviceSettings

    /// The daemon's device identifier.
    let udid: String
    var identifier: String { udid }
    var source: Settings.Source { .deviceServices }

    /// The audit service's text size slider runs from 0 to 1 over every size, accessibility sizes included.
    static func textSize(slider value: Double) -> Settings.TextSize {
        let sizes = Settings.TextSize.allCases
        let index = Int((min(max(value, 0), 1) * Double(sizes.count - 1)).rounded())
        return sizes[index]
    }

    static func slider(for size: Settings.TextSize) -> Double {
        let sizes = Settings.TextSize.allCases
        return Double(sizes.firstIndex(of: size) ?? 0) / Double(sizes.count - 1)
    }

    static func appearance(from settings: [String: Any]) -> Settings.Appearance {
        var appearance = Settings.Appearance()
        appearance.increaseContrast = settings["INCREASE_CONTRAST"] as? Bool
        appearance.reduceMotion = settings["REDUCE_MOTION"] as? Bool
        appearance.reduceTransparency = settings["REDUCE_TRANSPARENCY"] as? Bool
        // Button Shapes is the setting iOS now calls Show Borders.
        appearance.showBorders = settings["BUTTON_SHAPES"] as? Bool
        if let grayscale = settings["GRAYSCALE"] as? Bool {
            appearance.supportedColorFilters = [.grayscale]
            appearance.colorFilter = grayscale ? .grayscale : nil
        }
        appearance.textSize = (settings["DYNAMIC_TYPE"] as? NSNumber).map { textSize(slider: $0.doubleValue) }
        return appearance
    }

    /// The audit setting and value for a change, or nil when the service has no such setting.
    static func setting(for change: Settings.AppearanceChange) -> (name: String, value: Any)? {
        switch change {
        case .increaseContrast(let on): ("INCREASE_CONTRAST", on)
        case .reduceMotion(let on): ("REDUCE_MOTION", on)
        case .reduceTransparency(let on): ("REDUCE_TRANSPARENCY", on)
        case .showBorders(let on): ("BUTTON_SHAPES", on)
        case .colorFilter(nil): ("GRAYSCALE", false)
        case .colorFilter(.grayscale?): ("GRAYSCALE", true)
        case .textSize(let size): ("DYNAMIC_TYPE", slider(for: size))
        case .style, .tintedLiquidGlass, .liquidGlassOpacity, .colorFilter: nil
        }
    }

    private func daemon() async throws -> DaemonClient {
        try await DeviceHub.shared.daemon()
    }

    func appearance() async throws -> Settings.Appearance {
        Self.appearance(from: try await daemon().accessibilitySettings(udid))
    }

    func apply(_ change: Settings.AppearanceChange) async throws {
        guard let setting = Self.setting(for: change) else { throw Self.unsupported("\(change)") }
        _ = try await daemon().setAccessibilitySetting(udid, name: setting.name, value: setting.value)
    }

    func locations() async throws -> [Settings.Location] {
        Settings.Location.presets
    }

    func simulate(_ location: Settings.Location?) async throws {
        switch location?.kind {
        case .coordinate(let latitude, let longitude)?:
            try await daemon().simulateLocation(udid, latitude: latitude, longitude: longitude)
        case .scenario?:
            throw Self.unsupported("Location scenarios")
        case nil:
            try await daemon().clearLocation(udid)
        }
    }
}
