import Foundation

/// Developer tools that act on one running iOS simulator.
public enum SimulatorDeveloperAction: Sendable {
    case screenshotStatusBar
    case clearStatusBar
    case openURL(String)
    case push(bundleID: String, payload: String)

    public func validate() throws {
        switch self {
        case .screenshotStatusBar, .clearStatusBar:
            break
        case .openURL(let value):
            guard !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
                  let url = URL(string: value, encodingInvalidCharacters: false), let scheme = url.scheme,
                  !["http", "https"].contains(scheme.lowercased()) || url.host?.isEmpty == false else {
                throw DeviceHubError.serviceFailed("Enter an absolute URL with a scheme, such as myapp://item/1.")
            }
        case .push(let bundleID, let payload):
            guard bundleID.wholeMatch(of: #/[A-Za-z0-9][A-Za-z0-9-]*(?:\.[A-Za-z0-9-]+)*/#) != nil else {
                throw DeviceHubError.serviceFailed("Enter the target application's bundle identifier.")
            }
            guard payload.utf8.count <= 4096 else {
                throw DeviceHubError.serviceFailed("The APNs JSON payload must be 4096 bytes or less.")
            }
            guard let object = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any],
                  object["aps"] is [String: Any] else {
                throw DeviceHubError.serviceFailed("The APNs JSON payload must contain an aps dictionary.")
            }
        }
    }

    public func run(on device: DeviceSummary) async throws {
        try validate()
        if device.isSimulator && !device.isReady { throw DeviceHubError.deviceNotReady("Start the simulator first.") }
        let (id, developer) = try SimulatorLifecycle.target(device)
        let arguments: [String]
        switch self {
        case .screenshotStatusBar:
            arguments = ["status_bar", id, "override", "--time", "9:41", "--dataNetwork", "wifi",
                         "--wifiMode", "active", "--wifiBars", "3", "--cellularMode", "active",
                         "--cellularBars", "4", "--batteryState", "discharging", "--batteryLevel", "100"]
        case .clearStatusBar:
            arguments = ["status_bar", id, "clear"]
        case .openURL(let url):
            arguments = ["openurl", id, url]
        case .push(let bundleID, let payload):
            // simctl accepts a file or stdin. Give each request its own private payload file.
            let files = FileManager.default
            let directory = files.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try files.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            defer { try? files.removeItem(at: directory) }
            let file = directory.appendingPathComponent("notification.apns")
            try Data(payload.utf8).write(to: file)
            try await SimulatorTools.simctl(["push", id, bundleID, file.path], developerDirectory: developer)
            return
        }
        try await SimulatorTools.simctl(arguments, developerDirectory: developer)
    }
}
