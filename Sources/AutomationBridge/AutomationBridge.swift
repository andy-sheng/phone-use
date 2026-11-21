import CoreGraphics
import PhoneUseKit
import Foundation

private struct BridgeFailure: Error, CustomStringConvertible {
    let description: String
}

/// A private, parent-owned stdin/stdout channel. No listening ports or network API are exposed.
/// Images and incoming coordinates use native screenshot pixels; DeviceSession uses native
/// portrait normalized coordinates. MaaFramework handles its own recognition-image scaling.
///
/// `describe` resolves the device without opening a session. Android tasks use it to get the
/// adb serial and the daemon's adb executable, then drive the device with MaaFramework's own
/// AdbController; only iOS tasks send screenshots and input through this bridge.
@MainActor
func runAutomationBridge(deviceQuery: String?) async {
    var session: DeviceSession?
    var capture: ScreenshotVideoFallback?
    var heldPoint: (Double, Double)?

    func reply(_ object: [String: Any]) {
        guard var data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return }
        data.append(0x0A)
        FileHandle.standardOutput.write(data)
    }

    func number(_ params: [String: Any], _ name: String) throws -> Double {
        guard let value = params[name] as? NSNumber,
              CFGetTypeID(value) != CFBooleanGetTypeID(), value.doubleValue.isFinite else {
            throw BridgeFailure(description: "Missing or invalid number: \(name)")
        }
        return value.doubleValue
    }

    func point(_ params: [String: Any], x: String = "x", y: String = "y",
               session: DeviceSession) throws -> (Double, Double) {
        let px = try number(params, x), py = try number(params, y)
        guard px >= 0, py >= 0, px < session.display.pixelWidth, py < session.display.pixelHeight else {
            throw BridgeFailure(description: "Touch is outside the native screen")
        }
        return (px / session.display.pixelWidth, py / session.display.pixelHeight)
    }

    func release() async throws {
        guard let session, let point = heldPoint else { return }
        try await session.sendTouch(.ended, x: point.0, y: point.1)
        heldPoint = nil
    }

    do {
        for try await line in FileHandle.standardInput.bytes.lines {
            let request: [String: Any]
            do {
                guard let decoded = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else {
                    throw BridgeFailure(description: "Request must be a JSON object")
                }
                request = decoded
            } catch {
                reply(["id": NSNull(), "error": "Invalid JSON request"])
                continue
            }
            let id = request["id"] ?? NSNull()
            let params = request["params"] as? [String: Any] ?? [:]
            let started = ProcessInfo.processInfo.systemUptime
            let method = request["method"] as? String ?? ""
            var trace = ["request": String(describing: id), "method": method]
            Diagnostics.record("bridge.request.begin", trace)
            defer {
                trace["elapsed_ms"] = Diagnostics.elapsed(since: started)
                Diagnostics.record("bridge.request.end", trace)
            }
            do {
                if method == "release" {
                    try await release()
                    reply(["id": id, "result": [:]])
                    continue
                }
                if method == "describe" {
                    let device = try await DeviceHub.shared.device(for: deviceQuery)
                    guard device.isReady else {
                        throw BridgeFailure(description: "\(device.name) is not ready (\(device.state.rawValue))")
                    }
                    var result: [String: Any] = ["udid": device.udid, "name": device.name,
                                                 "platform": device.isAndroid ? "android" : "ios"]
                    if device.isAndroid {
                        result["serial"] = device.deviceIdentifier
                        result["adb"] = try await DeviceHub.shared.androidADBPath()
                    }
                    reply(["id": id, "result": result])
                    continue
                }
                let valid = ["connect", "screenshot", "click", "swipe", "touch_down", "touch_move", "touch_up", "launch"]
                guard valid.contains(method) else { throw BridgeFailure(description: "Unknown method: \(method)") }
                if session == nil { session = try await DeviceHub.shared.session(for: deviceQuery) }
                guard let session else { throw BridgeFailure(description: "Device session unavailable") }
                if capture == nil {
                    capture = ScreenshotVideoFallback(session: session)
                    capture?.prepare()
                }
                var result: [String: Any] = [:]
                switch method {
                case "connect":
                    result = ["udid": session.device.udid, "name": session.device.name,
                              "platform": session.device.isAndroid ? "android" : "ios",
                              "width": session.display.pixelWidth, "height": session.display.pixelHeight]
                case "screenshot":
                    guard let capture else { throw BridgeFailure(description: "Device session unavailable") }
                    let (image, source) = try await capture.screenshot()
                    guard image.width == Int(session.display.pixelWidth), image.height == Int(session.display.pixelHeight) else {
                        throw BridgeFailure(description: "Screen orientation changed; portrait automation must be restarted")
                    }
                    guard let png = ImageEncoding.png(image) else { throw BridgeFailure(description: "Screenshot encoding failed") }
                    result = ["png": png.base64EncodedString(), "width": image.width, "height": image.height,
                              "source": source.rawValue]
                case "click":
                    guard heldPoint == nil else { throw BridgeFailure(description: "A touch is already held") }
                    let p = try point(params, session: session)
                    heldPoint = p
                    try await session.sendTouch(.began, x: p.0, y: p.1)
                    try await Task.sleep(for: .milliseconds(50))
                    try await release()
                case "swipe":
                    guard heldPoint == nil else { throw BridgeFailure(description: "A touch is already held") }
                    let a = try point(params, x: "x1", y: "y1", session: session)
                    let b = try point(params, x: "x2", y: "y2", session: session)
                    let ms = try number(params, "duration_ms")
                    guard ms >= 1, ms <= 30_000 else { throw BridgeFailure(description: "Invalid swipe duration") }
                    heldPoint = a
                    try await session.swipe(fromX: a.0, fromY: a.1, toX: b.0, toY: b.1,
                                            duration: .milliseconds(Int(ms)))
                    heldPoint = nil
                case "touch_down", "touch_move":
                    if method == "touch_down", heldPoint != nil { throw BridgeFailure(description: "A touch is already held") }
                    if method == "touch_move", heldPoint == nil { throw BridgeFailure(description: "No touch is held") }
                    let p = try point(params, session: session)
                    heldPoint = p
                    try await session.sendTouch(method == "touch_down" ? .began : .moved, x: p.0, y: p.1)
                case "touch_up":
                    try await release()
                case "launch":
                    guard let bundleID = params["bundle_id"] as? String, !bundleID.isEmpty else {
                        throw BridgeFailure(description: "Missing bundle_id")
                    }
                    try await session.launchApp(bundleID: bundleID)
                default: break
                }
                reply(["id": id, "result": result])
            } catch {
                trace["error"] = String(describing: error)
                Diagnostics.record("bridge.request.failed", trace)
                try? await release()
                reply(["id": id, "error": String(describing: error)])
            }
        }
    } catch {
        FileHandle.standardError.write(Data("automation bridge: \(error)\n".utf8))
    }
    try? await release()
    capture?.stop()
    await session?.close()
}
