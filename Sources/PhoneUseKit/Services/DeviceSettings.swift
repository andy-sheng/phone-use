import Foundation

/// A device's appearance, accessibility, audio and location settings, and screen recording.
///
/// The richest available route is chosen per device: Xcode's `devicectl` when this Mac's Xcode
/// offers device settings, otherwise the daemon's accessibility audit and DVT services for
/// iPhone and iPad, or `simctl` for simulators. Each route reports only what it supports, so a
/// setting it cannot change comes back nil and every unsupported call throws.
public struct DeviceSettings: Sendable {
    public enum Source: String, Sendable {
        /// Xcode's `devicectl`, as used by Xcode's device window.
        case xcode
        /// The daemon's own device tunnel.
        case deviceServices
        /// `xcrun simctl`, on an Xcode without `devicectl` settings.
        case simctl
    }

    let backend: any DeviceSettingsBackend
    /// Recording is independent of the settings route; simulators always use simctl.
    let recordingBackend: (any DeviceSettingsBackend)?

    init(backend: any DeviceSettingsBackend, recordingBackend: (any DeviceSettingsBackend)? = nil) {
        self.backend = backend
        self.recordingBackend = recordingBackend
    }
    public var source: Source { backend.source }
    public var identifier: String { backend.identifier }
    /// Whether this route can record the screen.
    public var canRecord: Bool { (recordingBackend ?? backend).canRecord }

    /// Picks the route for a device, probing `devicectl` once per device. Nil for Android.
    public static func resolve(for device: DeviceSummary) async -> DeviceSettings? {
        guard !device.isAndroid else { return nil }
        let identifier = device.deviceIdentifier
        if await DeviceCtl.offersDeviceSettings {
            var xcode = DeviceCtlSettings(identifier: identifier)
            // CoreDevice may not know a device that only the daemon has paired.
            if device.isSimulator {
                return DeviceSettings(backend: xcode, recordingBackend: SimctlSettings(identifier: identifier))
            }
            if (try? await xcode.appearance()) != nil {
                // Appearance support alone is insufficient (for example, iOS 26.5).
                // Use the reported capability rather than assuming every iOS 27+ device offers it.
                if let details = try? await DeviceCtl.run(["device", "info", "details", "--device", identifier]) {
                    xcode.canRecord = DeviceCtlSettings.supportsRecording(details)
                }
                return DeviceSettings(backend: xcode)
            }
        }
        if device.isSimulator {
            return DeviceSettings(backend: SimctlSettings(identifier: identifier))
        }
        return DeviceSettings(backend: AccessibilityAuditSettings(udid: device.udid))
    }

    public func appearance() async throws -> Appearance { try await backend.appearance() }
    public func apply(_ change: AppearanceChange) async throws { try await backend.apply(change) }
    public func voiceOver() async throws -> Bool { try await backend.voiceOver() }
    public func setVoiceOver(_ enabled: Bool) async throws { try await backend.setVoiceOver(enabled) }
    public func audio() async throws -> Audio { try await backend.audio() }
    public func setAudio(volume: Int? = nil, output: AudioRoute? = nil, input: AudioRoute? = nil) async throws {
        try await backend.setAudio(volume: volume, output: output, input: input)
    }
    public func locations() async throws -> [Location] { try await backend.locations() }
    /// Simulates a location, or restores the real one for nil.
    public func simulate(_ location: Location?) async throws { try await backend.simulate(location) }
    /// Starts recording the device's primary display to a video file.
    public func startRecording(to destination: URL) throws -> ScreenRecording {
        try (recordingBackend ?? backend).startRecording(to: destination)
    }

    // MARK: Appearance

    /// Each property is nil when the route cannot read or change that setting.
    public struct Appearance: Sendable, Equatable {
        public var style: InterfaceStyle?
        /// The current Liquid Glass look, such as "Clear Liquid Glass", when the device offers a choice.
        public var lookAndFeel: String?
        public var supportedLooksAndFeels: [String] = []
        /// From 0 (fully translucent) to 1 (fully opaque), on devices that offer the slider.
        public var liquidGlassOpacity: Double?
        /// The filters this route can turn on; empty when it offers none.
        public var supportedColorFilters: [ColorFilter] = []
        /// Nil while no color filter is on.
        public var colorFilter: ColorFilter?
        public var textSize: TextSize?
        public var increaseContrast: Bool?
        public var reduceMotion: Bool?
        public var reduceTransparency: Bool?
        public var showBorders: Bool?

        public init() {}
    }

    public enum InterfaceStyle: String, Sendable, CaseIterable {
        case light, dark
    }

    public enum ColorFilter: String, Sendable, CaseIterable {
        case grayscale, protanopia, deuteranopia, tritanopia
    }

    public enum TextSize: String, Sendable, CaseIterable {
        case extraSmall = "extra-small"
        case small, medium, large
        case extraLarge = "extra-large"
        case extraExtraLarge = "extra-extra-large"
        case extraExtraExtraLarge = "extra-extra-extra-large"
        case accessibilityMedium = "accessibility-medium"
        case accessibilityLarge = "accessibility-large"
        case accessibilityExtraLarge = "accessibility-extra-large"
        case accessibilityExtraExtraLarge = "accessibility-extra-extra-large"
        case accessibilityExtraExtraExtraLarge = "accessibility-extra-extra-extra-large"

        /// The sizes offered without Larger Accessibility Sizes.
        public static let standard: [TextSize] = [.extraSmall, .small, .medium, .large,
                                                  .extraLarge, .extraExtraLarge, .extraExtraExtraLarge]

        public var isAccessibilitySize: Bool { !Self.standard.contains(self) }

        /// Sizes reported by name, such as "Extra Extra Large".
        init?(reportedName: String) {
            self.init(rawValue: reportedName.lowercased().replacingOccurrences(of: " ", with: "-"))
        }
    }

    public enum AppearanceChange: Sendable, Equatable {
        case style(InterfaceStyle)
        /// Selects the clear or tinted Liquid Glass look.
        case tintedLiquidGlass(Bool)
        case liquidGlassOpacity(Double)
        /// Nil turns the color filter off.
        case colorFilter(ColorFilter?)
        case textSize(TextSize)
        case increaseContrast(Bool)
        case reduceMotion(Bool)
        case reduceTransparency(Bool)
        case showBorders(Bool)
    }

    // MARK: Audio

    /// Where the device's sound goes to or comes from on this Mac.
    public enum AudioRoute: Sendable, Hashable {
        case systemDefault
        /// A Core Audio device UID.
        case device(String)
    }

    public struct Audio: Sendable, Equatable {
        /// From 0 to 100.
        public var volume: Int?
        public var output: AudioRoute
        public var input: AudioRoute
    }

    // MARK: Location

    public struct Location: Sendable, Hashable, Identifiable {
        public enum Kind: Sendable, Hashable {
            /// One of the device's predefined scenarios, which may move along a route.
            case scenario(String)
            case coordinate(latitude: Double, longitude: Double)
        }

        public let name: String
        public let kind: Kind
        public var id: String { name }

        public init(name: String, kind: Kind) {
            self.name = name
            self.kind = kind
        }

        /// Fixed places offered where the device has no scenarios of its own.
        public static let presets: [Location] = [
            Location(name: "Apple", kind: .coordinate(latitude: 37.33182, longitude: -122.03118)),
            Location(name: "Beijing", kind: .coordinate(latitude: 39.9042, longitude: 116.4074)),
            Location(name: "Shanghai", kind: .coordinate(latitude: 31.2304, longitude: 121.4737)),
            Location(name: "Tokyo", kind: .coordinate(latitude: 35.6762, longitude: 139.6503)),
            Location(name: "London", kind: .coordinate(latitude: 51.5074, longitude: -0.1278)),
            Location(name: "New York", kind: .coordinate(latitude: 40.7128, longitude: -74.0060)),
        ]
    }
}

/// One route to a device's settings. Defaults throw for what the route does not offer.
protocol DeviceSettingsBackend: Sendable {
    var source: DeviceSettings.Source { get }
    var identifier: String { get }
    var canRecord: Bool { get }
    func appearance() async throws -> DeviceSettings.Appearance
    func apply(_ change: DeviceSettings.AppearanceChange) async throws
    func voiceOver() async throws -> Bool
    func setVoiceOver(_ enabled: Bool) async throws
    func audio() async throws -> DeviceSettings.Audio
    func setAudio(volume: Int?, output: DeviceSettings.AudioRoute?, input: DeviceSettings.AudioRoute?) async throws
    func locations() async throws -> [DeviceSettings.Location]
    func simulate(_ location: DeviceSettings.Location?) async throws
    func startRecording(to destination: URL) throws -> ScreenRecording
}

extension DeviceSettingsBackend {
    var canRecord: Bool { false }
    func voiceOver() async throws -> Bool { throw Self.unsupported("VoiceOver") }
    func setVoiceOver(_ enabled: Bool) async throws { throw Self.unsupported("VoiceOver") }
    func audio() async throws -> DeviceSettings.Audio { throw Self.unsupported("Audio") }
    func setAudio(volume: Int?, output: DeviceSettings.AudioRoute?, input: DeviceSettings.AudioRoute?) async throws {
        throw Self.unsupported("Audio")
    }
    func startRecording(to destination: URL) throws -> ScreenRecording { throw Self.unsupported("Screen recording") }

    static func unsupported(_ name: String) -> DeviceHubError {
        .capabilityUnavailable(name)
    }
}

/// A recording from a preview stream or a platform tool.
public protocol ScreenRecordingSession: AnyObject, Sendable {
    var destination: URL { get }
    var isRunning: Bool { get }
    func stop() async throws -> URL
}

/// A platform tool that saves the video when interrupted.
public final class ScreenRecording: ScreenRecordingSession, @unchecked Sendable {
    public let destination: URL
    private let process: Process
    private let errors = Pipe()
    private let finished: ProcessTermination

    init(process: Process, destination: URL) throws {
        self.destination = destination
        self.process = process
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errors
        finished = ProcessTermination(process)
        try process.run()
    }

    public var isRunning: Bool { process.isRunning }

    /// Interrupts the tool as Ctrl-C would, which makes it write the file, and waits for that.
    public func stop() async throws -> URL {
        if process.isRunning { process.interrupt() }
        _ = await finished.wait()
        guard FileManager.default.fileExists(atPath: destination.path) else {
            let detail = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw DeviceHubError.serviceFailed(detail.isEmpty ? "The screen recording was not saved." : detail)
        }
        return destination
    }
}
