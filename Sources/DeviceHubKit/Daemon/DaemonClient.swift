import Foundation

/// JSON-RPC client for the daemon's Unix socket (newline-delimited JSON).
public actor DaemonClient {
    public struct OpenedDevice: Decodable, Sendable {
        public let udid: String
        public let productVersion: String?
        public let services: [String]
        public let display: DisplayInfo?
    }

    struct Port: Decodable {
        let port: UInt16
    }

    struct Devices: Decodable {
        let devices: [DeviceSummary]
    }

    struct Mirror: Decodable {
        let port: UInt16
        let path: String
    }

    private let stream: ByteStream
    private var nextID = 1
    private var pending: [Int: CheckedContinuation<Data, Error>] = [:]
    private var subscribers: [UUID: AsyncStream<[DeviceSummary]>.Continuation] = [:]
    private var failure: Error?

    public static func connect(socket: String = DeviceHubPaths.socket) async throws -> DaemonClient {
        let client = DaemonClient(socket: socket)
        do {
            try await client.stream.open(timeout: .seconds(2))
        } catch {
            throw DeviceHubError.daemonUnavailable("\(error)")
        }
        await client.startReading()
        return client
    }

    /// Whether a daemon answers on `socket` right now.
    public static func isReachable(socket: String = DeviceHubPaths.socket) async -> Bool {
        let stream = ByteStream(unixSocket: socket)
        defer { stream.close() }
        do {
            try await stream.open(timeout: .seconds(1))
            return true
        } catch {
            return false
        }
    }

    private init(socket: String) {
        stream = ByteStream(unixSocket: socket)
    }

    public var isConnected: Bool { failure == nil }

    public func close() {
        fail(DeviceHubError.connectionClosed)
    }

    // MARK: Methods

    public func devices() async throws -> [DeviceSummary] {
        try await call("listDevices", as: Devices.self).devices
    }

    /// Current devices first, then every change.
    public func deviceUpdates() async throws -> AsyncStream<[DeviceSummary]> {
        let (updates, continuation) = AsyncStream<[DeviceSummary]>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let token = UUID()
        subscribers[token] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeSubscriber(token) }
        }
        let current = try await call("subscribe", as: Devices.self).devices
        continuation.yield(current)
        return updates
    }

    public func pair(_ udid: String) async throws {
        try await callIgnoringResult("pair", ["udid": udid])
    }

    public func startWirelessPairing() async throws -> WirelessPairingStatus {
        try await call("startWirelessPairing", as: WirelessPairingStatus.self)
    }

    public func wirelessPairingStatus(_ sessionID: String) async throws -> WirelessPairingStatus {
        try await call("wirelessPairingStatus", ["sessionID": sessionID], as: WirelessPairingStatus.self)
    }

    public func pairNearbyDevice(_ deviceID: String, sessionID: String) async throws {
        try await callIgnoringResult("pairNearbyDevice", ["sessionID": sessionID, "deviceID": deviceID])
    }

    public func stopWirelessPairing(_ sessionID: String) async throws {
        try await callIgnoringResult("stopWirelessPairing", ["sessionID": sessionID])
    }

    public func revealDeveloperMode(_ udid: String) async throws {
        try await callIgnoringResult("revealDeveloperMode", ["udid": udid])
    }

    public func mountDeveloperImage(_ udid: String) async throws {
        try await callIgnoringResult("mountDeveloperImage", ["udid": udid])
    }

    public func openDevice(_ udid: String) async throws -> OpenedDevice {
        try await call("openDevice", ["udid": udid], as: OpenedDevice.self)
    }

    public func closeDevice(_ udid: String) async throws {
        try await callIgnoringResult("closeDevice", ["udid": udid])
    }

    /// Android actions are sent once. A failed reply must never replay a gesture or launch.
    public func androidCommand(_ udid: String, action: String, params: [String: String] = [:]) async throws -> Data {
        var payload = params
        payload["udid"] = udid
        payload["action"] = action
        return try await rawCall("androidCommand", payload)
    }

    func openService(_ udid: String, service: String) async throws -> UInt16 {
        try await call("openService", ["udid": udid, "service": service], as: Port.self).port
    }

    /// Starts (or joins) the device's mirror stream and returns its HTTP URL.
    public func startMirror(_ udid: String) async throws -> URL {
        let mirror = try await call("startMirror", ["udid": udid], as: Mirror.self)
        return URL(string: "http://127.0.0.1:\(mirror.port)\(mirror.path)")!
    }

    public func stopMirror(_ udid: String) async throws {
        try await callIgnoringResult("stopMirror", ["udid": udid])
    }

    /// The device's accessibility audit settings, such as `REDUCE_MOTION` or `DYNAMIC_TYPE`.
    func accessibilitySettings(_ udid: String) async throws -> [String: Any] {
        try Self.settings(in: await rawCall("accessibilitySettings", ["udid": udid]))
    }

    /// Updates one accessibility audit setting and returns all of them as the device now reports.
    func setAccessibilitySetting(_ udid: String, name: String, value: Any) async throws -> [String: Any] {
        let encoded = try JSONSerialization.data(withJSONObject: value, options: .fragmentsAllowed)
        return try Self.settings(in: await rawCall("setAccessibilitySetting", [
            "udid": udid, "name": name, "value": String(decoding: encoded, as: UTF8.self),
        ]))
    }

    /// Simulates the device's location until cleared or the device closes.
    func simulateLocation(_ udid: String, latitude: Double, longitude: Double) async throws {
        try await callIgnoringResult("simulateLocation", ["udid": udid, "latitude": String(latitude),
                                                          "longitude": String(longitude)])
    }

    func clearLocation(_ udid: String) async throws {
        try await callIgnoringResult("clearLocation", ["udid": udid])
    }

    private static func settings(in data: Data) throws -> [String: Any] {
        guard let result = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let settings = result["settings"] as? [String: Any] else {
            throw DeviceHubError.serviceFailed("The daemon returned no accessibility settings")
        }
        return settings
    }

    /// The daemon issues `secrets.token_urlsafe` tokens; the consumer writes one back as a line.
    private static let videoTokenBytes = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_".utf8)

    public func startAndroidVideo(_ udid: String) async throws -> AndroidVideoEndpoint {
        let endpoint = try await call("startAndroidVideo", ["udid": udid], as: AndroidVideoEndpoint.self)
        let token = endpoint.token.utf8
        guard endpoint.port != 0, (16...128).contains(token.count),
              token.allSatisfy(Self.videoTokenBytes.contains) else {
            throw DeviceHubError.serviceFailed("Android video returned an invalid endpoint")
        }
        return endpoint
    }

    public func stopAndroidVideo(_ udid: String, token: String) async throws {
        try await callIgnoringResult("stopAndroidVideo", ["udid": udid, "token": token])
    }

    // MARK: Transport

    private func callIgnoringResult(_ method: String, _ params: [String: String]) async throws {
        _ = try await rawCall(method, params)
    }

    private func call<T: Decodable>(_ method: String, _ params: [String: String] = [:], as type: T.Type) async throws -> T {
        let data = try await rawCall(method, params)
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func rawCall(_ method: String, _ params: [String: String]) async throws -> Data {
        if let failure { throw DeviceHubError.daemonUnavailable("\(failure)") }
        let id = nextID
        nextID += 1
        var line = try JSONSerialization.data(withJSONObject: ["id": id, "method": method, "params": params])
        line.append(0x0A)
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            Task {
                do {
                    try await stream.write(line)
                } catch {
                    self.fail(error)
                }
            }
        }
    }

    private func startReading() {
        Task { await readLoop() }
    }

    private func readLoop() async {
        do {
            while true {
                let line = try await stream.readLine()
                guard let message = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
                if let id = message["id"] as? Int, let continuation = pending.removeValue(forKey: id) {
                    if let error = message["error"] as? [String: Any] {
                        continuation.resume(throwing: DeviceHubError.daemon(
                            code: error["code"] as? String ?? "internal",
                            message: error["message"] as? String ?? "Daemon request failed"))
                    } else {
                        let result = message["result"] ?? [String: Any]()
                        continuation.resume(returning: (try? JSONSerialization.data(withJSONObject: result)) ?? Data("{}".utf8))
                    }
                } else if message["method"] as? String == "devicesChanged",
                          let params = message["params"],
                          let data = try? JSONSerialization.data(withJSONObject: params),
                          let devices = try? JSONDecoder().decode(Devices.self, from: data) {
                    for subscriber in subscribers.values { subscriber.yield(devices.devices) }
                }
            }
        } catch {
            fail(error)
        }
    }

    private func removeSubscriber(_ token: UUID) {
        subscribers[token] = nil
    }

    private func fail(_ error: Error) {
        guard failure == nil else { return }
        failure = error
        stream.close()
        let waiting = pending
        pending.removeAll()
        for continuation in waiting.values {
            continuation.resume(throwing: DeviceHubError.daemonUnavailable("\(error)"))
        }
        for subscriber in subscribers.values { subscriber.finish() }
        subscribers.removeAll()
    }
}
