import Foundation

/// A RemoteXPC client connection to one device service, reached through a daemon port forward.
///
/// Messages go out on HTTP/2 stream 1; the service answers on stream 3. Requests that want a
/// reply are answered in order, so replies are matched to waiters first-in, first-out.
actor RemoteXPCConnection {
    private static let rootStream: UInt32 = 1
    private static let replyStream: UInt32 = 3
    private static let localWindow: UInt32 = 16 * 1024 * 1024
    private static let windowUpdateThreshold = 1024 * 1024
    private static let maxFrameSize = 16384

    let port: UInt16
    private let stream: ByteStream
    private var nextMessageID: UInt64 = 0
    private var readerTask: Task<Void, Never>?
    private let writeLock = AsyncLock()
    private let requestLock = AsyncLock()
    private var replyWaiters: [ReplySlot] = []
    private var windowWaiters: [CheckedContinuation<Void, Never>] = []
    private var pendingBuffers: [UInt32: Data] = [:]
    private var unacknowledged: [UInt32: Int] = [:]
    private var peerInitialWindow = 65535
    private var connectionWindow = 65535
    private var streamWindows: [UInt32: Int] = [:]
    private(set) var failure: Error?

    var isOpen: Bool { failure == nil && readerTask != nil }

    init(port: UInt16) {
        self.port = port
        stream = ByteStream(port: port)
    }

    func connect() async throws {
        try await stream.open()
        try await stream.write(HTTP2Frame.preface)
        try await writeFrame(.settings([
            (HTTP2Frame.settingsMaxConcurrentStreams, UInt32(100)),
            (HTTP2Frame.settingsInitialWindowSize, Self.localWindow),
        ]))
        try await writeFrame(.windowUpdate(stream: 0, increment: Self.localWindow - 65535))
        try await writeFrame(HTTP2Frame(.headers, flags: HTTP2Frame.endHeaders, stream: Self.rootStream))
        // Frame order matters to the device: it rejects the session unless stream 3 is opened
        // between the empty root message and its 0x0201 terminator.
        try await sendMessage([:], wantsReply: false)
        try await writeFrame(HTTP2Frame(.headers, flags: HTTP2Frame.endHeaders, stream: Self.replyStream))
        try await writeData(XPCCodec.encodeWrapper(.init(flags: 0x0201, messageID: 0, payload: nil)), stream: Self.rootStream)
        let handshake = XPCCodec.Flags([.alwaysSet, .initHandshake]).rawValue
        try await writeData(XPCCodec.encodeWrapper(.init(flags: handshake, messageID: 0, payload: nil)), stream: Self.replyStream)

        while true {
            let frame = try await readFrame()
            applyFlowControl(frame)
            if frame.kind == .settings, frame.flags & HTTP2Frame.ack == 0 { break }
        }
        try await writeFrame(HTTP2Frame(.settings, flags: HTTP2Frame.ack, stream: 0))
        readerTask = Task { await self.readLoop() }
    }

    /// Sends a message without waiting for an answer.
    func send(_ message: XPCDictionary) async throws {
        try check()
        await writeLock.acquire()
        defer { writeLock.release() }
        try await sendMessage(message, wantsReply: false)
    }

    /// Sends a message and waits for the service's reply. One request is outstanding at a time.
    func request(_ message: XPCDictionary, timeout: Duration = .seconds(20)) async throws -> XPCDictionary {
        try check()
        await requestLock.acquire()
        defer { requestLock.release() }
        try check()
        let timeoutTask = Task { [weak self] in
            try await Task.sleep(for: timeout)
            Diagnostics.record("xpc.reply.timeout", ["port": String(self?.port ?? 0), "timeout": String(describing: timeout)])
            await self?.fail(DeviceHubError.timeout("waiting for a reply on port \(self?.port ?? 0)"))
        }
        defer { timeoutTask.cancel() }
        let slot = ReplySlot()
        replyWaiters.append(slot)
        await writeLock.acquire()
        do {
            try await sendMessage(message, wantsReply: true)
            writeLock.release()
        } catch {
            writeLock.release()
            fail(error)
        }
        return try await slot.value()
    }

    func close() {
        fail(DeviceHubError.connectionClosed)
    }

    // MARK: Writing

    private func check() throws {
        if let failure { throw failure }
    }

    private func sendMessage(_ message: XPCDictionary, wantsReply: Bool) async throws {
        var flags: XPCCodec.Flags = .alwaysSet
        if !message.isEmpty { flags.insert(.dataPresent) }
        if wantsReply { flags.insert(.wantingReply) }
        let wrapper = XPCCodec.encodeWrapper(.init(flags: flags.rawValue, messageID: nextMessageID, payload: .dictionary(message)))
        // Each side numbers its messages with its own parity; ours are odd after the handshake.
        nextMessageID = (nextMessageID + 1) | 1
        try await writeData(wrapper, stream: Self.rootStream)
    }

    private func writeData(_ data: Data, stream streamID: UInt32) async throws {
        var offset = 0
        while offset < data.count {
            var budget = min(connectionWindow, streamWindows[streamID] ?? peerInitialWindow, Self.maxFrameSize)
            while budget <= 0 {
                try check()
                await withCheckedContinuation { windowWaiters.append($0) }
                budget = min(connectionWindow, streamWindows[streamID] ?? peerInitialWindow, Self.maxFrameSize)
            }
            let chunk = data.subdata(in: offset ..< min(offset + budget, data.count))
            connectionWindow -= chunk.count
            streamWindows[streamID] = (streamWindows[streamID] ?? peerInitialWindow) - chunk.count
            try await writeFrame(HTTP2Frame(.data, stream: streamID, payload: chunk))
            offset += chunk.count
        }
    }

    private func writeFrame(_ frame: HTTP2Frame) async throws {
        try await stream.write(frame.serialized())
    }

    // MARK: Reading

    private func readFrame() async throws -> HTTP2Frame {
        let header = try await stream.read(exactly: HTTP2Frame.headerSize)
        let length = HTTP2Frame.payloadLength(header: header)
        let payload = length > 0 ? try await stream.read(exactly: length) : Data()
        return HTTP2Frame.parse(header: header, payload: payload)
    }

    private func applyFlowControl(_ frame: HTTP2Frame) {
        switch frame.kind {
        case .windowUpdate:
            if frame.streamID == 0 {
                connectionWindow += frame.windowIncrement
            } else {
                streamWindows[frame.streamID] = (streamWindows[frame.streamID] ?? peerInitialWindow) + frame.windowIncrement
            }
        case .settings where frame.flags & HTTP2Frame.ack == 0:
            if let initial = frame.settingsValues[HTTP2Frame.settingsInitialWindowSize] {
                let delta = Int(initial) - peerInitialWindow
                peerInitialWindow = Int(initial)
                for key in streamWindows.keys { streamWindows[key]! += delta }
            }
        default:
            return
        }
        let waiters = windowWaiters
        windowWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    private func readLoop() async {
        do {
            while true {
                let frame = try await readFrame()
                applyFlowControl(frame)
                switch frame.kind {
                case .data:
                    try await receiveData(frame)
                case .ping where frame.flags & HTTP2Frame.ack == 0:
                    try await writeFrame(HTTP2Frame(.ping, flags: HTTP2Frame.ack, stream: 0, payload: frame.payload))
                case .goAway:
                    throw DeviceHubError.connectionClosed
                case .rstStream:
                    throw DeviceHubError.connectionClosed
                default:
                    break
                }
            }
        } catch {
            fail(error)
        }
    }

    private func receiveData(_ frame: HTTP2Frame) async throws {
        guard !frame.payload.isEmpty else { return }
        let total = (unacknowledged[frame.streamID] ?? 0) + frame.payload.count
        if total >= Self.windowUpdateThreshold {
            unacknowledged[frame.streamID] = 0
            try await writeFrame(.windowUpdate(stream: 0, increment: UInt32(total)))
            try await writeFrame(.windowUpdate(stream: frame.streamID, increment: UInt32(total)))
        } else {
            unacknowledged[frame.streamID] = total
        }

        var buffer = (pendingBuffers[frame.streamID] ?? Data()) + frame.payload
        while let (wrapper, length) = try XPCCodec.decodeWrapper(buffer) {
            buffer = buffer.subdata(in: buffer.startIndex + length ..< buffer.endIndex)
            if case .dictionary(let reply) = wrapper.payload, !reply.isEmpty, !replyWaiters.isEmpty {
                replyWaiters.removeFirst().resolve(.success(reply))
            }
            if buffer.isEmpty { break }
        }
        pendingBuffers[frame.streamID] = buffer
    }

    private func fail(_ error: Error) {
        if failure == nil { failure = error }
        stream.close()
        readerTask?.cancel()
        let waiters = replyWaiters
        replyWaiters.removeAll()
        waiters.forEach { $0.resolve(.failure(error)) }
        let windows = windowWaiters
        windowWaiters.removeAll()
        windows.forEach { $0.resume() }
    }
}

/// A reply that may arrive before or after someone starts waiting for it.
final class ReplySlot: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<XPCDictionary, Error>?
    private var continuation: CheckedContinuation<XPCDictionary, Error>?

    func resolve(_ value: Result<XPCDictionary, Error>) {
        lock.lock()
        guard result == nil else { lock.unlock(); return }
        result = value
        let waiting = continuation
        continuation = nil
        lock.unlock()
        waiting?.resume(with: value)
    }

    func value() async throws -> XPCDictionary {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if let result {
                lock.unlock()
                continuation.resume(with: result)
            } else {
                self.continuation = continuation
                lock.unlock()
            }
        }
    }
}

/// A FIFO mutex for async code.
final class AsyncLock: @unchecked Sendable {
    private let lock = NSLock()
    private var locked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if locked {
                waiters.append(continuation)
                lock.unlock()
            } else {
                locked = true
                lock.unlock()
                continuation.resume()
            }
        }
    }

    func release() {
        lock.lock()
        if waiters.isEmpty {
            locked = false
            lock.unlock()
        } else {
            let next = waiters.removeFirst()
            lock.unlock()
            next.resume()
        }
    }
}
