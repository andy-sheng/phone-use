import Foundation

/// The identity of the application using PhoneUseKit: where its daemon keeps state and listens,
/// where logs go, and the name nearby iPhones show for this Mac while pairing.
///
/// Every app sets `current` once at launch, before anything talks to the daemon, so two apps built
/// on the kit keep separate daemons. Helper processes inherit the choice through `environment`;
/// without an explicit setting a process reads `DEVICEHUB_HOME` (and the matching display name and
/// log variables), falling back to phone-use's identity.
public struct PhoneUseConfiguration: Sendable, Equatable {
    /// Daemon state: its socket, device cache and anything else the daemon persists.
    public var supportDirectory: URL
    /// Daemon and Android controller logs.
    public var logDirectory: URL
    /// Shown on iPhones and iPads during nearby pairing and in user-facing daemon errors.
    public var displayName: String

    public init(supportDirectory: URL, logDirectory: URL, displayName: String) {
        self.supportDirectory = supportDirectory
        self.logDirectory = logDirectory
        self.displayName = displayName
    }

    /// phone-use keeps the DeviceHub locations so existing installs retain their state.
    public static let phoneUse = PhoneUseConfiguration(
        supportDirectory: library("Application Support/DeviceHub"),
        logDirectory: library("Logs/DeviceHub"),
        displayName: "phone-use"
    )

    /// An app that keeps its daemon state under its own bundle identifier.
    public static func application(identifier: String, displayName: String) -> PhoneUseConfiguration {
        PhoneUseConfiguration(supportDirectory: library("Application Support/\(identifier)"),
                              logDirectory: library("Logs/\(identifier)"),
                              displayName: displayName)
    }

    /// Where the daemon listens. `DEVICEHUB_SOCKET` still overrides it, for tests and debugging.
    public var socketPath: String {
        if let override = ProcessInfo.processInfo.environment["DEVICEHUB_SOCKET"], !override.isEmpty {
            return override
        }
        return supportDirectory.appendingPathComponent("devicehubd.sock").path
    }

    /// Variables that carry this identity to the daemon and helper processes.
    public var environment: [String: String] {
        [
            Self.homeVariable: supportDirectory.path,
            Self.logVariable: logDirectory.path,
            Self.displayNameVariable: displayName,
        ]
    }

    static let homeVariable = "DEVICEHUB_HOME"
    static let logVariable = "DEVICEHUB_LOG_DIR"
    static let displayNameVariable = "DEVICEHUB_DISPLAY_NAME"

    /// Reads an identity a parent process passed through `environment`, if any.
    public static func inherited(from environment: [String: String] = ProcessInfo.processInfo.environment)
        -> PhoneUseConfiguration? {
        guard let home = environment[homeVariable], !home.isEmpty else { return nil }
        let support = URL(fileURLWithPath: home, isDirectory: true)
        let logs = environment[logVariable].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }
        return PhoneUseConfiguration(supportDirectory: support,
                                     logDirectory: logs ?? support.appendingPathComponent("Logs", isDirectory: true),
                                     displayName: environment[displayNameVariable].flatMap { $0.isEmpty ? nil : $0 }
                                         ?? support.lastPathComponent)
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var explicit: PhoneUseConfiguration?

    /// The identity this process uses. Set it before the first daemon connection.
    public static var current: PhoneUseConfiguration {
        get { lock.withLock { explicit } ?? inherited() ?? .phoneUse }
        set { lock.withLock { explicit = newValue } }
    }

    private static func library(_ path: String) -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent(path, isDirectory: true)
    }
}
