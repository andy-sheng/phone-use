import Foundation

/// A device as reported by the daemon.
public struct DeviceSummary: Codable, Hashable, Identifiable, Sendable {
    public enum Platform: String, Codable, Sendable {
        case ios
        case android
    }

    public enum State: String, Codable, Sendable {
        case disconnected
        case probing
        case untrusted
        case developerModeOff
        case developerImageMissing
        case ready
        case unauthorized
        case offline
    }

    public var id: String { udid }
    public let udid: String
    public let platform: Platform
    /// How the Mac reaches the device: `usb`, `network` (Wi-Fi), `emulator` (Android) or
    /// `simulator` (an iOS simulator booted on this Mac).
    public let connection: String
    public let name: String
    public let productType: String?
    public private(set) var productVersion: String?
    public let buildVersion: String?
    public let state: State
    public let paired: Bool?
    public let developerMode: Bool?
    public let developerImage: Bool?
    /// Whether the device is paired for Wi-Fi, which happens on its own while it is on USB.
    public let wireless: Bool?
    /// `closed`, `opening`, `open` or `failed`.
    public let session: String
    public let error: String?

    private enum CodingKeys: String, CodingKey {
        case udid, platform, connection, name, productType, productVersion, buildVersion, state
        case paired, developerMode, developerImage, wireless, session, error
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        udid = try values.decode(String.self, forKey: .udid)
        // Older daemons only discover Apple devices and do not send this field.
        platform = try values.decodeIfPresent(Platform.self, forKey: .platform) ?? .ios
        connection = try values.decode(String.self, forKey: .connection)
        name = try values.decode(String.self, forKey: .name)
        productType = try values.decodeIfPresent(String.self, forKey: .productType)
        productVersion = try values.decodeIfPresent(String.self, forKey: .productVersion)
        buildVersion = try values.decodeIfPresent(String.self, forKey: .buildVersion)
        state = try values.decode(State.self, forKey: .state)
        paired = try values.decodeIfPresent(Bool.self, forKey: .paired)
        developerMode = try values.decodeIfPresent(Bool.self, forKey: .developerMode)
        developerImage = try values.decodeIfPresent(Bool.self, forKey: .developerImage)
        wireless = try values.decodeIfPresent(Bool.self, forKey: .wireless)
        session = try values.decode(String.self, forKey: .session)
        error = try values.decodeIfPresent(String.self, forKey: .error)
    }

    public var isAttached: Bool { state != .disconnected }

    /// A device paired entirely over Wi-Fi may first learn its OS version when
    /// the worker opens its tunnel. Use that version for video and HID policy.
    func withProductVersion(_ version: String?) -> DeviceSummary {
        var updated = self
        updated.productVersion = version ?? productVersion
        return updated
    }

    public var isReady: Bool { state == .ready }
    public var isWired: Bool { connection == "usb" }
    /// An iOS simulator, controlled in-process through CoreSimulator rather than a device link.
    public var isSimulator: Bool { platform == .ios && connection == "simulator" }
    public var connectionDescription: String {
        switch connection {
        case "usb": "USB"
        case "network": "Wi-Fi"
        case "simulator": "Simulator"
        default: connection.capitalized
        }
    }
    public var osMajorVersion: Int {
        Int(productVersion?.split(separator: ".").first ?? "") ?? 0
    }
    public var osDescription: String? { productVersion.map { "\(isAndroid ? "Android" : isPad ? "iPadOS" : "iOS") \($0)" } }
    public var isAndroid: Bool { platform == .android }
    public var isPad: Bool { !isAndroid && productType?.hasPrefix("iPad") == true }
    public var platformName: String { isAndroid ? "Android" : isPad ? "iPad" : "iPhone" }
    public var deviceIcon: String { isAndroid ? "candybarphone" : isPad ? "ipad" : "iphone" }
    public var deviceIdentifier: String {
        if isAndroid && udid.hasPrefix("android:") { return String(udid.dropFirst("android:".count)) }
        if isSimulator && udid.hasPrefix("simulator:") { return String(udid.dropFirst("simulator:".count)) }
        return udid
    }

    /// Marketing name for recent models, the hardware identifier otherwise.
    public var modelName: String? {
        guard let productType else { return nil }
        return isAndroid ? productType : Self.marketingNames[productType] ?? productType
    }

    private static let marketingNames: [String: String] = [
        "iPhone14,7": "iPhone 14", "iPhone14,8": "iPhone 14 Plus",
        "iPhone15,2": "iPhone 14 Pro", "iPhone15,3": "iPhone 14 Pro Max",
        "iPhone15,4": "iPhone 15", "iPhone15,5": "iPhone 15 Plus",
        "iPhone16,1": "iPhone 15 Pro", "iPhone16,2": "iPhone 15 Pro Max",
        "iPhone17,1": "iPhone 16 Pro", "iPhone17,2": "iPhone 16 Pro Max",
        "iPhone17,3": "iPhone 16", "iPhone17,4": "iPhone 16 Plus", "iPhone17,5": "iPhone 16e",
        "iPhone18,1": "iPhone 17 Pro", "iPhone18,2": "iPhone 17 Pro Max",
        "iPhone18,3": "iPhone 17", "iPhone18,4": "iPhone Air",
    ]
}

public struct DisplayInfo: Codable, Sendable {
    public let pixelWidth: Double
    public let pixelHeight: Double
    public let pointScale: Double

    public var pointWidth: Double { pixelWidth / pointScale }
    public var pointHeight: Double { pixelHeight / pointScale }
}

public enum TouchPhase: Sendable {
    case began
    case moved
    case ended
}

public enum HardwareButton: String, CaseIterable, Sendable {
    case home
    case lock
    case volumeUp = "volume_up"
    case volumeDown = "volume_down"
    case siri
    case back
    case appSwitch = "app_switch"

    var usage: (page: UInt64, code: UInt64)? {
        switch self {
        case .home: (0x0C, 0x40)
        case .lock: (0x0C, 0x30)
        case .volumeUp: (0x0C, 0xE9)
        case .volumeDown: (0x0C, 0xEA)
        case .siri: (0x0C, 0xCF)
        case .back, .appSwitch: nil
        }
    }

    /// iOS reads the side button's hold time: a short tap does not sleep the device or start Siri.
    var defaultHold: Duration {
        switch self {
        case .lock: .milliseconds(500)
        case .siri: .seconds(1)
        default: .milliseconds(60)
        }
    }
}

public enum DeviceHubError: Error, CustomStringConvertible, Sendable {
    case daemonUnavailable(String)
    case daemon(code: String, message: String)
    case deviceNotFound(String)
    case deviceNotReady(String)
    case capabilityUnavailable(String)
    case serviceFailed(String)
    case connectionClosed
    case timeout(String)

    public var description: String {
        switch self {
        case .daemonUnavailable(let detail):
            "\(PhoneUseConfiguration.current.displayName) is not running (\(detail)). Open \(PhoneUseConfiguration.current.displayName) first."
        case .daemon(_, let message): message
        case .deviceNotFound(let query): "No device matches '\(query)'"
        case .deviceNotReady(let detail): detail
        case .capabilityUnavailable(let name): "Device does not offer capability: \(name)"
        case .serviceFailed(let detail): detail
        case .connectionClosed: "The connection to the device closed"
        case .timeout(let what): "Timed out \(what)"
        }
    }
}
