import Foundation
import CoreGraphics
import Network
import PhoneUseKit

enum WebPreviewHTTP {
    static let boundary = "phoneuse-frame"

    struct Request {
        let method: String
        let path: String
        let headers: [String: String]
        let body: Data

        func authorizesInput(token: String) -> Bool {
            guard headers["x-phoneuse-token"] == token,
                  headers["content-type"]?.lowercased().split(separator: ";").first == "application/json" else { return false }
            if let origin = headers["origin"], origin != "http://" + (headers["host"] ?? "") { return false }
            return true
        }
    }

    enum InvalidRequest: Error { case malformed }

    /// nil means the bounded request is incomplete, including a body split across TCP reads.
    static func parse(_ data: Data, port: UInt16) throws -> Request? {
        guard data.count <= 16384 else { throw InvalidRequest.malformed }
        guard let separator = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        guard let text = String(data: data[..<separator.lowerBound], encoding: .utf8) else { throw InvalidRequest.malformed }
        let lines = text.components(separatedBy: "\r\n")
        let request = (lines.first ?? "").split(separator: " ")
        guard request.count == 3, ["GET", "POST"].contains(request[0]), request[2] == "HTTP/1.1" else { throw InvalidRequest.malformed }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { throw InvalidRequest.malformed }
            let key = String(line[..<colon]).lowercased()
            guard !key.isEmpty, key == key.trimmingCharacters(in: .whitespaces), headers[key] == nil else { throw InvalidRequest.malformed }
            headers[key] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        guard let host = headers["host"], ["127.0.0.1:\(port)", "localhost:\(port)"].contains(host.lowercased()),
              headers["transfer-encoding"] == nil else { throw InvalidRequest.malformed }
        let length: Int
        if let raw = headers["content-length"] {
            guard !raw.isEmpty, raw.allSatisfy({ $0.isASCII && $0.isNumber }), let count = Int(raw), count <= 8192 else { throw InvalidRequest.malformed }
            length = count
        } else {
            guard request[0] == "GET" else { throw InvalidRequest.malformed }
            length = 0
        }
        guard request[0] != "GET" || length == 0 else { throw InvalidRequest.malformed }
        let expected = separator.upperBound + length
        guard data.count >= expected else { return nil }
        guard data.count == expected else { throw InvalidRequest.malformed }
        return Request(method: String(request[0]), path: String(request[1]), headers: headers, body: Data(data[separator.upperBound...]))
    }

    static func route(_ data: Data, port: UInt16) -> String? {
        guard let request = try? parse(data, port: port), request.method == "GET" else { return nil }
        return request.path
    }

    static func response(_ status: String, type: String, body: Data) -> Data {
        Data("HTTP/1.1 \(status)\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\nCache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\nContent-Security-Policy: frame-ancestors 'none'\r\nConnection: close\r\n\r\n".utf8) + body
    }

    static func frame(_ jpeg: Data) -> Data {
        Data("--\(boundary)\r\nContent-Type: image/jpeg\r\nContent-Length: \(jpeg.count)\r\n\r\n".utf8) + jpeg + Data("\r\n".utf8)
    }
}

/// Loopback HTTP preview with authenticated input. One frame in flight per client, bounded connections and
/// request headers; a slow consumer skips frames instead of growing a video queue.
@MainActor
final class WebPreviewServer {
    private final class Client {
        let connection: NWConnection
        var request = Data()
        var streaming = false
        var webSocket = false
        var needsKey = true
        var sending = false
        init(_ connection: NWConnection) { self.connection = connection }
    }

    private let listener: NWListener
    private let port: UInt16
    private let deviceName: String
    private let deviceID: String
    private let streamKind: String
    private let controlToken = UUID().uuidString + UUID().uuidString
    private let isAndroid: Bool
    private let performInput: (WebInputCommand) async throws -> Void
    private var inputBusy = false
    private var inputTask: Task<Void, Never>?
    private var clients: [UUID: Client] = [:]
    private var latestJPEG = Data()
    private var frames = 0
    private var frameTime = Date()
    private(set) var running = false
    private var videoAvailable = true
    private var forceKey = false
    private var videoFrames = 0
    private var videoSize = [0, 0]
    var hasVideoClients: Bool { clients.values.contains { $0.webSocket } }
    var hasJPEGClients: Bool { clients.values.contains { $0.streaming && !$0.webSocket } }
    func takeKeyRequest() -> Bool { let value = forceKey; forceKey = false; return value }

    func publishVideo(_ frame: WebH264Frame) {
        videoFrames += 1; videoSize = [frame.width, frame.height]
        let packet = frame.packet
        let config = (try? JSONSerialization.data(withJSONObject: ["type": "config", "codec": frame.codec,
            "width": frame.width, "height": frame.height])) ?? Data()
        for (id, client) in clients where client.webSocket {
            // Losing a reference frame requires an IDR before any further deltas.
            if client.sending { client.needsKey = true; continue }
            if client.needsKey && !frame.key { continue }
            client.needsKey = false
            send((frame.key ? WebSocketVideo.frame(config, opcode: 1) : Data()) + packet, to: id, close: false)
        }
    }

    func disableVideo() {
        videoAvailable = false
        for id in clients.keys.filter({ clients[$0]?.webSocket == true }) { remove(id) }
    }

    private func receiveVideo(_ id: UUID) {
        guard let client = clients[id] else { return }
        client.connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, complete, error in
            Task { @MainActor in
                guard let self, let client = self.clients[id] else { return }
                guard error == nil, !complete else { self.remove(id); return }
                if let data { client.request.append(data) }
                do {
                    while let message = try WebSocketVideo.read(&client.request) {
                        switch message.opcode {
                        case 1:
                            guard message.payload == Data("keyframe".utf8) else { self.remove(id); return }
                            // Periodic IDRs satisfy recovery requests without allowing an unbounded encode workload.
                            client.needsKey = true
                        case 8: self.remove(id); return
                        case 9:
                            guard !client.sending else { self.remove(id); return }
                            self.send(WebSocketVideo.frame(message.payload, opcode: 10), to: id, close: false)
                        default: break
                        }
                    }
                    self.receiveVideo(id)
                } catch { self.remove(id) }
            }
        }
    }

    init(port: UInt16, deviceName: String, deviceID: String, streamKind: String, isAndroid: Bool = false,
         performInput: @escaping (WebInputCommand) async throws -> Void) throws {
        self.port = port
        self.deviceName = deviceName
        self.deviceID = deviceID
        self.streamKind = streamKind
        self.isAndroid = isAndroid
        self.performInput = performInput
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
        listener = try NWListener(using: parameters)
    }

    func start() async throws {
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in self?.accept(connection) }
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            var waiting = true
            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    switch state {
                    case .ready:
                        if waiting { waiting = false; self?.running = true; continuation.resume() }
                    case .failed(let error), .waiting(let error):
                        if waiting { waiting = false; continuation.resume(throwing: error) }
                        self?.stop()
                    default: break
                    }
                }
            }
            listener.start(queue: .main)
        }
    }

    func stop() {
        running = false
        listener.cancel()
        inputTask?.cancel()
        for client in clients.values { client.connection.cancel() }
        clients.removeAll()
    }

    func finishInput() async { await inputTask?.value }

    func publish(_ jpeg: Data) {
        latestJPEG = jpeg
        frames += 1
        frameTime = Date()
        let part = WebPreviewHTTP.frame(jpeg)
        for (id, client) in clients where client.streaming && !client.webSocket && !client.sending {
            send(part, to: id, close: false)
        }
    }

    private func accept(_ connection: NWConnection) {
        guard running, clients.count < 16 else { connection.cancel(); return }
        let id = UUID()
        clients[id] = Client(connection)
        connection.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                switch state {
                case .failed, .cancelled: self?.remove(id)
                default: break
                }
            }
        }
        connection.start(queue: .main)
        receive(id)
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            if let client = self?.clients[id], !client.streaming { self?.remove(id) }
        }
    }

    private func receive(_ id: UUID) {
        guard let client = clients[id] else { return }
        client.connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, complete, error in
            Task { @MainActor in
                guard let self, let client = self.clients[id] else { return }
                if let data { client.request.append(data) }
                guard client.request.count <= 16384, error == nil else { self.remove(id); return }
                do {
                    if let request = try WebPreviewHTTP.parse(client.request, port: self.port) {
                        self.respond(id, request: request)
                    } else if complete { self.remove(id) }
                    else { self.receive(id) }
                } catch {
                    self.reply(id, status: "400 Bad Request", type: "text/plain", body: Data("Invalid request".utf8))
                }
            }
        }
    }

    private func respond(_ id: UUID, request: WebPreviewHTTP.Request) {
        guard let client = clients[id] else { return }
        client.request.removeAll()
        if request.method == "POST" {
            guard request.path == "/input" else {
                reply(id, status: "404 Not Found", type: "text/plain", body: Data("Not found".utf8))
                return
            }
            handleInput(id, request: request)
            return
        }
        if request.path.hasPrefix("/video") {
            guard videoAvailable, let response = WebSocketVideo.handshake(request, token: controlToken) else {
                reply(id, status: "403 Forbidden", type: "text/plain", body: Data("Video unavailable".utf8)); return
            }
            client.streaming = true; client.webSocket = true; forceKey = true
            send(response, to: id, close: false)
            receiveVideo(id)
            return
        }
        switch request.path {
        case "/":
            reply(id, type: "text/html; charset=utf-8", body: Data(Self.page.replacingOccurrences(of: "CONTROL_TOKEN", with: controlToken)
                .replacingOccurrences(of: "ANDROID_HIDDEN", with: isAndroid ? "" : "hidden").utf8))
        case "/stream.mjpeg":
            client.streaming = true
            send(Data("HTTP/1.1 200 OK\r\nContent-Type: multipart/x-mixed-replace; boundary=\(WebPreviewHTTP.boundary)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n".utf8) + (latestJPEG.isEmpty ? Data() : WebPreviewHTTP.frame(latestJPEG)), to: id, close: false)
        case "/snapshot.jpg":
            if latestJPEG.isEmpty { reply(id, status: "503 Service Unavailable", type: "text/plain", body: Data("Waiting for device video".utf8)) }
            else { reply(id, type: "image/jpeg", body: latestJPEG) }
        case "/health":
            let body = (try? JSONSerialization.data(withJSONObject: [
                "service": "phone-use-web", "device_id": deviceID,
                "device": deviceName, "source": streamKind, "frames": frames,
                "frameAgeSeconds": Date().timeIntervalSince(frameTime),
                "videoFrames": videoFrames, "videoSize": videoSize, "videoAvailable": videoAvailable,
            ])) ?? Data()
            reply(id, type: "application/json", body: body)
        default:
            reply(id, status: "404 Not Found", type: "text/plain", body: Data("Not found".utf8))
        }
    }

    private func handleInput(_ id: UUID, request: WebPreviewHTTP.Request) {
        guard request.authorizesInput(token: controlToken) else {
            inputReply(id, status: "403 Forbidden", error: "控制凭证无效，请刷新网页")
            return
        }
        guard !inputBusy else {
            inputReply(id, status: "409 Conflict", error: "设备正在执行操作，请稍后重试")
            return
        }
        let command: WebInputCommand
        do { command = try WebInputCommand.decode(request.body) }
        catch { inputReply(id, status: "400 Bad Request", error: String(describing: error)); return }
        inputBusy = true
        inputTask = Task { [self] in
            defer { inputBusy = false; inputTask = nil }
            do {
                try Task.checkCancellation()
                try await performInput(command)
                inputReply(id)
            } catch { inputReply(id, status: "502 Bad Gateway", error: String(describing: error)) }
        }
    }

    private func inputReply(_ id: UUID, status: String = "200 OK", error: String? = nil) {
        let body = (try? JSONSerialization.data(withJSONObject: error.map { ["error": $0] } ?? ["status": "ok"])) ?? Data()
        reply(id, status: status, type: "application/json", body: body)
    }

    private func reply(_ id: UUID, status: String = "200 OK", type: String, body: Data) {
        send(WebPreviewHTTP.response(status, type: type, body: body), to: id, close: true)
    }

    private func send(_ data: Data, to id: UUID, close: Bool) {
        guard let client = clients[id] else { return }
        client.sending = true
        client.connection.send(content: data, completion: .contentProcessed { [weak self] error in
            Task { @MainActor in
                guard let self else { return }
                if close || error != nil { self.remove(id) }
                else { self.clients[id]?.sending = false }
            }
        })
    }

    private func remove(_ id: UUID) { clients.removeValue(forKey: id)?.connection.cancel() }


}

@MainActor
func serveWebPreview(deviceQuery: String?, port: UInt16) async throws {
    let hub = DeviceHub.shared
    let device = try await hub.device(for: deviceQuery)
    await prepareScreenSession(for: device)
    let session = try await hub.session(for: device.udid)
    guard let stream = await makeVideoScreenStream(for: session, captureFrames: true) else {
        throw DeviceHubError.serviceFailed("No video stream is available for \(device.name)")
    }
    defer { stream.stop() }
    let server = try WebPreviewServer(port: port, deviceName: device.name, deviceID: device.udid, streamKind: stream.kind.rawValue,
        isAndroid: device.isAndroid) { command in try await command.execute(on: session) }
    defer { server.stop() }
    var streamError: String?
    stream.onError = { streamError = $0; server.stop() }
    let jpegEncoder = WebVideoEncoder()
    let videoEncoder = WebH264Encoder()
    if let streamError { throw DeviceHubError.serviceFailed(streamError) }
    // A sleeping USB device can take time to emit its first frame. Keep the local page
    // available while waiting; health remains at frames=0 and snapshots return 503.
    try await server.start()
    signal(SIGINT, SIG_IGN)
    signal(SIGTERM, SIG_IGN)
    let signals = [SIGINT, SIGTERM].map { value -> DispatchSourceSignal in
        let source = DispatchSource.makeSignalSource(signal: value, queue: .main)
        source.setEventHandler { Task { @MainActor in server.stop() } }
        source.resume()
        return source
    }
    defer { signals.forEach { $0.cancel() } }
    FileHandle.standardError.write(Data("Web preview: http://127.0.0.1:\(port)/\nStream: http://127.0.0.1:\(port)/stream.mjpeg\nSource: \(device.name) · \(stream.kind.rawValue)\n".utf8))
    var jpegTask: Task<Void, Never>?
    var jpegBusy = false
    var jpegAt = 0.0
    while server.running {
        let start = ProcessInfo.processInfo.systemUptime
        if let frame = WebVideoFrame.latest(from: stream) {
            let jpegInterval = server.hasJPEGClients ? 1.0 / 30 : 0.5
            if !jpegBusy && start - jpegAt >= jpegInterval {
                jpegBusy = true; jpegAt = start
                let profile: WebVideoProfile = server.hasJPEGClients ? .balanced : .detail
                jpegTask = Task { @MainActor in
                    defer { jpegBusy = false }
                    if let jpeg = await jpegEncoder.encode(frame, profile: profile) { server.publish(jpeg.jpeg) }
                }
            }
            if server.hasVideoClients {
                do {
                    if let video = try await videoEncoder.encode(frame, forceKey: server.takeKeyRequest()) { server.publishVideo(video) }
                } catch {
                    FileHandle.standardError.write(Data("Web H.264 fallback: \(error)\n".utf8))
                    server.disableVideo()
                }
            }
        }
        let fps = server.hasVideoClients ? 60 : (server.hasJPEGClients ? 30 : 2)
        let delay = WebVideoProfile.delay(framesPerSecond: fps, elapsed: ProcessInfo.processInfo.systemUptime - start)
        if delay > 0 { try await Task.sleep(for: .seconds(delay)) }
    }
    await jpegTask?.value
    await server.finishInput()
    if let streamError { throw DeviceHubError.serviceFailed(streamError) }
}

