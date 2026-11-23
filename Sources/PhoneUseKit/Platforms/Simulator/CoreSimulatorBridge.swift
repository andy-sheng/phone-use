import CoreGraphics
import AppKit
import Foundation
import IOSurface
import ObjectiveC
import XPC

/// Xcode's simulator frameworks, loaded at runtime so phone-use still starts on Macs without Xcode.
///
/// CoreSimulator finds booted devices and their framebuffer; SimulatorKit builds and sends the
/// same Indigo HID messages Simulator.app uses. Only this file touches the private interfaces.
final class CoreSimulatorBridge: @unchecked Sendable {
    typealias MouseMessage = @convention(c) (UnsafePointer<CGPoint>, UnsafePointer<CGPoint>?, UInt32, UInt,
                                             CGSize, UInt32) -> UnsafeMutableRawPointer?
    typealias ButtonMessage = @convention(c) (UInt32, UInt32, UInt32) -> UnsafeMutableRawPointer?
    typealias ArbitraryMessage = @convention(c) (UInt32, UInt32, UInt32, UInt32) -> UnsafeMutableRawPointer?
    typealias KeyboardMessage = @convention(c) (UInt32, UInt32) -> UnsafeMutableRawPointer?

    let developerDirectory: String
    let mouseMessage: MouseMessage
    let buttonMessage: ButtonMessage
    let arbitraryMessage: ArbitraryMessage
    let keyboardMessage: KeyboardMessage?

    private static let lock = NSLock()
    nonisolated(unsafe) private static var loaded: CoreSimulatorBridge?

    /// A failure is not cached: installing or selecting Xcode later works without a restart.
    static func shared() throws -> CoreSimulatorBridge {
        lock.lock()
        defer { lock.unlock() }
        if let loaded { return loaded }
        let bridge = try CoreSimulatorBridge()
        loaded = bridge
        return bridge
    }

    private init() throws {
        guard let developer = SimulatorTools.developerDirectory() else {
            throw DeviceHubError.capabilityUnavailable("iOS Simulator (install Xcode and select it with xcode-select)")
        }
        let coreSimulator = ["/Library/Developer/PrivateFrameworks/CoreSimulator.framework/CoreSimulator",
                             "\(developer)/Library/PrivateFrameworks/CoreSimulator.framework/CoreSimulator"]
        guard coreSimulator.contains(where: { dlopen($0, RTLD_NOW) != nil }) else {
            throw DeviceHubError.serviceFailed("Cannot load CoreSimulator from Xcode at \(developer)")
        }
        let simulatorKitPath = URL(fileURLWithPath: developer).deletingLastPathComponent()
            .appendingPathComponent("SharedFrameworks/SimulatorKit.framework/SimulatorKit").path
        guard let simulatorKit = dlopen(simulatorKitPath, RTLD_NOW),
              let mouse = dlsym(simulatorKit, "IndigoHIDMessageForMouseNSEvent"),
              let button = dlsym(simulatorKit, "IndigoHIDMessageForButton"),
              let arbitrary = dlsym(simulatorKit, "IndigoHIDMessageForHIDArbitrary") else {
            throw DeviceHubError.serviceFailed("This Xcode's SimulatorKit does not offer simulator input")
        }
        developerDirectory = developer
        mouseMessage = unsafeBitCast(mouse, to: MouseMessage.self)
        buttonMessage = unsafeBitCast(button, to: ButtonMessage.self)
        arbitraryMessage = unsafeBitCast(arbitrary, to: ArbitraryMessage.self)
        keyboardMessage = dlsym(simulatorKit, "IndigoHIDMessageForKeyboardArbitrary").map { unsafeBitCast($0, to: KeyboardMessage.self) }
    }

    /// The booted `SimDevice` with this CoreSimulator UDID.
    func bootedDevice(_ identifier: String) throws -> AnyObject {
        guard let contextClass = NSClassFromString("SimServiceContext") as AnyObject?,
              let context = Self.object(contextClass, "sharedServiceContextForDeveloperDir:error:",
                                        developerDirectory as NSString, nil),
              let set = Self.object(context, "defaultDeviceSetWithError:", nil),
              let devices = set.value(forKey: "devices") as? [AnyObject] else {
            throw DeviceHubError.serviceFailed("CoreSimulator did not return its device set")
        }
        guard let device = devices.first(where: {
            ($0.value(forKey: "UDID") as? NSUUID)?.uuidString.caseInsensitiveCompare(identifier) == .orderedSame
        }) else {
            throw DeviceHubError.deviceNotFound(identifier)
        }
        // SimDeviceState: 3 is Booted.
        guard (device.value(forKey: "state") as? NSNumber)?.intValue == 3 else {
            throw DeviceHubError.deviceNotReady("The simulator is not booted")
        }
        return device
    }

    func hidClient(for device: AnyObject) throws -> AnyObject {
        guard let hidClass = NSClassFromString("_TtC12SimulatorKit24SimDeviceLegacyHIDClient") as AnyObject?,
              let allocated = hidClass.perform(NSSelectorFromString("alloc")),
              let client = allocated.takeUnretainedValue()
                .perform(NSSelectorFromString("initWithDevice:error:"), with: device, with: nil) else {
            throw DeviceHubError.serviceFailed("Cannot open the simulator's HID connection")
        }
        // `init` consumed the allocation and returned an owned reference.
        return client.takeRetainedValue()
    }

    /// The device's built-in display, which renders into an IOSurface shared with this process.
    func mainDisplays(of device: AnyObject) throws -> [SimulatorDisplay.Panel] {
        guard let renderable = objc_getProtocol("SimDisplayIOSurfaceRenderable"),
              let io = Self.object(device, "io"),
              let ports = Self.object(io, "ioPorts") as? [AnyObject] else {
            throw DeviceHubError.serviceFailed("CoreSimulator did not list the simulator's displays")
        }
        var panels: [SimulatorDisplay.Panel] = []
        for port in ports {
            guard let descriptor = Self.object(port, "descriptor"), descriptor.conforms(to: renderable),
                  let state = Self.object(descriptor, "state") else { continue }
            let selector = NSSelectorFromString("displayClass")
            guard state.responds(to: selector) else { continue }
            typealias DisplayClass = @convention(c) (AnyObject, Selector) -> UInt16
            // Display class 0 is the main screen; external displays and CarPlay use others.
            if unsafeBitCast(state.method(for: selector), to: DisplayClass.self)(state, selector) == 0 {
                guard let uuid = Self.object(port, "uuid") as? NSUUID else { continue }
                panels.append(.init(descriptor: descriptor, identifier: uuid.uuidString))
            }
        }
        guard !panels.isEmpty else { throw DeviceHubError.capabilityUnavailable("simulator main display") }
        return panels
    }

    func pointScale(of device: AnyObject) -> Double {
        let type = device.value(forKey: "deviceType") as AnyObject?
        let scale = (type?.value(forKey: "mainScreenScale") as? NSNumber)?.doubleValue ?? 0
        return scale.isFinite && scale > 0 ? scale : 1
    }

    func modernInput(for device: AnyObject) async throws -> SimulatorHIDChannel? {
        let version = (NSClassFromString("SimDevice").map { Bundle(for: $0) })?.infoDictionary?["CFBundleVersion"] as? String
        Diagnostics.record("simulator.input_transport", ["core_simulator": version ?? "unknown", "transport": SimulatorInput.requiresModernHID(version: version) ? "dtuhid" : "indigo"])
        guard SimulatorInput.requiresModernHID(version: version) else { return nil }
        return try await SimulatorHIDChannel.open(device)
    }

    /// Sends one message created by a SimulatorKit builder; the client frees it.
    func send(_ message: UnsafeMutableRawPointer, through client: AnyObject) async throws {
        typealias Send = @convention(c) (AnyObject, Selector, UnsafeMutableRawPointer, Bool, DispatchQueue?,
                                         (@convention(block) (NSError?) -> Void)?) -> Void
        let selector = NSSelectorFromString("sendWithMessage:freeWhenDone:completionQueue:completion:")
        guard client.responds(to: selector) else {
            free(message)
            throw DeviceHubError.serviceFailed("This Xcode's simulator HID client cannot send messages")
        }
        let send = unsafeBitCast(client.method(for: selector), to: Send.self)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            send(client, selector, message, true, DispatchQueue.global(qos: .userInteractive)) { error in
                if let error {
                    continuation.resume(throwing: DeviceHubError.serviceFailed("Simulator input failed: \(error.localizedDescription)"))
                } else {
                    continuation.resume()
                }
            }
        }
    }

    /// Registers an ObjC block callback under `uuid` (`registerCallbackWithUUID:<kind>:`).
    static func register(_ target: AnyObject, _ name: String, uuid: NSUUID, block: AnyObject) {
        typealias Register = @convention(c) (AnyObject, Selector, NSUUID, AnyObject) -> Void
        let selector = NSSelectorFromString(name)
        guard target.responds(to: selector) else { return }
        unsafeBitCast(target.method(for: selector), to: Register.self)(target, selector, uuid, block)
    }

    /// Calls a one-argument method that returns `void`; `perform` would read its result as an object.
    static func invoke(_ target: AnyObject, _ name: String, _ argument: AnyObject) {
        typealias Method = @convention(c) (AnyObject, Selector, AnyObject) -> Void
        let selector = NSSelectorFromString(name)
        guard target.responds(to: selector) else { return }
        unsafeBitCast(target.method(for: selector), to: Method.self)(target, selector, argument)
    }

    /// Calls a method that returns an object (or nil), with up to two object arguments.
    static func object(_ target: AnyObject, _ name: String, _ arguments: Any?...) -> AnyObject? {
        let selector = NSSelectorFromString(name)
        guard target.responds(to: selector) else { return nil }
        let result = switch arguments.count {
        case 0: target.perform(selector)
        case 1: target.perform(selector, with: arguments[0])
        default: target.perform(selector, with: arguments[0], with: arguments[1])
        }
        return result?.takeUnretainedValue()
    }
}

/// Xcode 27's DTUHID service. Legacy Indigo callbacks can succeed while the guest drops the
/// event, so modern toolchains must establish a live channel instead of falling back silently.
final class SimulatorHIDChannel: @unchecked Sendable {
    static let digitizerService = "com.apple.coredevice.feature.remote.hid.digitizer"
    static let vendorService = "com.apple.coredevice.feature.remote.hid.vendordefined"
    private let service: String
    private let connection: xpc_connection_t
    private let queue = DispatchQueue(label: "PhoneUseKit.simulator-hid")
    private let lock = NSLock()
    private var disconnected = false

    private init(_ connection: xpc_connection_t, service: String) {
        self.connection = connection
        self.service = service
        xpc_connection_set_target_queue(connection, queue)
        xpc_connection_set_event_handler(connection) { [weak self] event in
            if xpc_get_type(event) == XPC_TYPE_ERROR { self?.lock.withLock { self?.disconnected = true } }
        }
        xpc_connection_resume(connection)
    }

    static func open(_ device: AnyObject, service: String = digitizerService) async throws -> SimulatorHIDChannel {
        typealias Endpoint = @convention(c) (UInt32, UInt64, UInt64) -> Unmanaged<AnyObject>?
        typealias Connect = @convention(c) (xpc_object_t) -> Unmanaged<AnyObject>?
        typealias Enable = @convention(c) (xpc_connection_t) -> Void
        guard let handle = dlopen(nil, RTLD_NOW),
              let endpointSymbol = dlsym(handle, "xpc_endpoint_create_mach_port_4sim"),
              let connectSymbol = dlsym(handle, "xpc_connection_create_from_endpoint"),
              let enableSymbol = dlsym(handle, "xpc_connection_enable_sim2host_4sim") else {
            throw DeviceHubError.capabilityUnavailable("CoreSimulator DTUHID connection symbols in this toolchain")
        }
        defer { dlclose(handle) }
        let lookup = NSSelectorFromString("lookup:error:")
        typealias Lookup = @convention(c) (AnyObject, Selector, NSString, AutoreleasingUnsafeMutablePointer<NSError?>?) -> UInt32
        guard device.responds(to: lookup) else { throw DeviceHubError.capabilityUnavailable("CoreSimulator service lookup") }
        var error: NSError?
        let port = unsafeBitCast(device.method(for: lookup), to: Lookup.self)(device, lookup, service as NSString, &error)
        guard port != 0 else { throw DeviceHubError.serviceFailed("Simulator input service is unavailable: \(error?.localizedDescription ?? "service not found"). Wait for boot to finish and reconnect") }
        guard let endpoint = unsafeBitCast(endpointSymbol, to: Endpoint.self)(port, 0, 0)?.takeRetainedValue() as? xpc_object_t,
              let connection = unsafeBitCast(connectSymbol, to: Connect.self)(endpoint)?.takeRetainedValue() as? xpc_connection_t else {
            throw DeviceHubError.serviceFailed("Cannot create the simulator's DTUHID channel")
        }
        unsafeBitCast(enableSymbol, to: Enable.self)(connection)
        let channel = SimulatorHIDChannel(connection, service: service)
        do {
            if service == digitizerService { try await channel.barrier() }
            try await Task.sleep(for: .milliseconds(200))
            return channel
        } catch {
            channel.close()
            throw error
        }
    }

    private func message(_ type: String, payload: xpc_object_t, barrier: Bool = false) -> xpc_object_t {
        let object = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_string(object, "messageType", type)
        xpc_dictionary_set_string(object, "featureIdentifier", service)
        xpc_dictionary_set_bool(object, "isBarrier", barrier)
        xpc_dictionary_set_value(object, "payload", payload)
        return object
    }

    private func requireConnected() throws {
        guard !lock.withLock({ disconnected }) else {
            throw DeviceHubError.serviceFailed("The simulator input channel disconnected. Inspect the current UI and reconnect before retrying; input is not replayed")
        }
    }

    private func send(_ type: String, payload: xpc_object_t) async throws {
        try requireConnected()
        xpc_connection_send_message(connection, message(type, payload: payload))
        await withCheckedContinuation { continuation in
            xpc_connection_send_barrier(connection) { continuation.resume() }
        }
        try requireConnected()
    }

    private final class Reply: @unchecked Sendable {
        let lock = NSLock()
        var continuation: CheckedContinuation<Void, Error>?
        init(_ continuation: CheckedContinuation<Void, Error>) { self.continuation = continuation }
        func finish(_ result: Result<Void, Error>) {
            let pending = lock.withLock { let value = continuation; continuation = nil; return value }
            pending?.resume(with: result)
        }
    }

    /// A no-key event that demands a reply: service lookup alone does not prove dtuhidd is alive.
    private func barrier() async throws {
        let payload = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_uint64(payload, "usageCode", 0)
        xpc_dictionary_set_uint64(payload, "state", 2)
        let message = message("IndigoKeyboardButtonEvent", payload: payload, barrier: true)
        try await request(message)
    }

    private func request(_ message: xpc_object_t) async throws {
        try requireConnected()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let answer = Reply(continuation)
            queue.asyncAfter(deadline: .now() + 4) {
                answer.finish(.failure(DeviceHubError.timeout("waiting for the simulator input service; reconnect once boot completes")))
            }
            xpc_connection_send_message_with_reply(connection, message, queue) { reply in
                if xpc_get_type(reply) == XPC_TYPE_ERROR {
                    answer.finish(.failure(DeviceHubError.serviceFailed("The simulator input service did not accept its connection")))
                } else { answer.finish(.success(())) }
            }
        }
    }

    func key(_ code: UInt32, down: Bool) async throws {
        let payload = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_uint64(payload, "usageCode", UInt64(code))
        xpc_dictionary_set_uint64(payload, "state", down ? 1 : 2)
        try await send("IndigoKeyboardButtonEvent", payload: payload)
    }

    func button(page: UInt64, code: UInt64, down: Bool) async throws {
        let payload = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_uint64(payload, "usagePage", page)
        xpc_dictionary_set_uint64(payload, "usageCode", code)
        xpc_dictionary_set_uint64(payload, "state", down ? 1 : 2)
        try await send("IndigoButtonEvent", payload: payload)
    }

    func touch(_ phase: TouchPhase, x: Double, y: Double, target: UInt64 = 0) async throws {
        let point = xpc_dictionary_create(nil, nil, 0), payload = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_double(point, "x", x)
        xpc_dictionary_set_double(point, "y", y)
        xpc_dictionary_set_value(payload, "pointOne", point)
        xpc_dictionary_set_uint64(payload, "eventType", phase == .began ? 0 : phase == .moved ? 1 : 2)
        xpc_dictionary_set_uint64(payload, "edge", 0)
        xpc_dictionary_set_uint64(payload, "target", target)
        try await send("IndigoDigitizerEvent", payload: payload)
    }

    /// DeviceHub's Pop plugin sends an IOCF binary dictionary on vendor page FF61/usage 5B.
    /// Keep the service separate from the digitizer so its report is routed to the hinge sensor.
    func setPosture(_ posture: SimulatorPosture) async throws {
        try await sendVirtualMachineControl(posture.command)
    }

    func setOrientation(_ orientation: DeviceOrientation) async throws {
        try await sendVirtualMachineControl(orientation.command)
    }

    private func sendVirtualMachineControl(_ command: [String: Any]) async throws {
        typealias Serialize = @convention(c) (CFTypeRef, UInt32) -> Unmanaged<CFData>?
        guard let handle = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW) else {
            throw DeviceHubError.capabilityUnavailable("IOKit simulator control serialization")
        }
        defer { dlclose(handle) }
        guard let symbol = dlsym(handle, "IOCFSerialize"),
              let serialized = unsafeBitCast(symbol, to: Serialize.self)(command as NSDictionary, 1) else {
            throw DeviceHubError.serviceFailed("Could not encode the simulator control command")
        }
        let data = serialized.takeRetainedValue() as Data
        let payload = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_uint64(payload, "usagePage", 0xff61)
        xpc_dictionary_set_uint64(payload, "usage", 0x5b)
        xpc_dictionary_set_uint64(payload, "version", 0)
        data.withUnsafeBytes { xpc_dictionary_set_data(payload, "data", $0.baseAddress, $0.count) }
        try await send("IndigoVendorDefinedEvent", payload: payload)
        // A barrier acknowledges earlier events but does not dispatch its own payload.
        try await request(message("IndigoVendorDefinedEvent", payload: payload, barrier: true))
    }

    func drain() async throws { try await Task.sleep(for: .milliseconds(80)); try requireConnected() }
    func close() { lock.withLock { disconnected = true }; xpc_connection_cancel(connection) }
    deinit { xpc_connection_cancel(connection) }
}

// AccessibilityPlatformTranslation calls back synchronously while CoreSimulator is async.
// All translator use is serialized off the main thread; its process-wide delegate is never
// replaced by another device until the complete traversal/action has finished.
private let simulatorAXQueue = DispatchQueue(label: "PhoneUseKit.simulator-accessibility")

extension CoreSimulatorBridge {
    func accessibility(_ identifier: String, target: UISelector? = nil, focus: Bool = false) async throws -> UITree {
        try await withCheckedThrowingContinuation { continuation in
            simulatorAXQueue.async {
                do {
                    guard dlopen("/System/Library/PrivateFrameworks/AccessibilityPlatformTranslation.framework/AccessibilityPlatformTranslation", RTLD_NOW) != nil,
                          let cls = NSClassFromString("AXPTranslator") as AnyObject?,
                          let translator = Self.object(cls, "sharedInstance") else {
                        throw DeviceHubError.capabilityUnavailable("Simulator accessibility translation in this Xcode/macOS version")
                    }
                    let delegate = SimulatorAXDelegate(device: try self.bootedDevice(identifier))
                    Self.invoke(translator, "setBridgeTokenDelegate:", delegate)
                    Self.invoke(translator, "setBridgeDelegate:", delegate)
                    defer {
                        // AXPTranslator's delegates are weak; keep this request's owner alive throughout.
                        withExtendedLifetime(delegate) {}
                    }
                    let selector = NSSelectorFromString("frontmostApplicationWithDisplayId:bridgeDelegateToken:")
                    typealias Frontmost = @convention(c) (AnyObject, Selector, UInt32, NSString) -> AnyObject?
                    guard translator.responds(to: selector),
                          let translation = unsafeBitCast(translator.method(for: selector), to: Frontmost.self)(translator, selector, 0, UUID().uuidString as NSString),
                          let root = Self.object(translator, "macPlatformElementFromTranslation:", translation) else {
                        throw DeviceHubError.serviceFailed("The simulator accessibility bridge returned no foreground app. Wait for the app to finish launching, then retry describe_ui. If it persists, ask the user to restart the simulator")
                    }
                    var elements: [UIElement] = [], handles: [AnyObject] = []
                    var seen = Set<ObjectIdentifier>(), truncated = false
                    func walk(_ element: AnyObject, depth: Int) throws {
                        try delegate.check()
                        guard depth <= 32, elements.count < 500 else { truncated = true; return }
                        guard seen.insert(ObjectIdentifier(element)).inserted else { return }
                        let role = (Self.object(element, "accessibilityRole") as? String ?? "AXUnknown")
                        let type = role.hasPrefix("AX") ? String(role.dropFirst(2)) : role
                        let subrole = Self.object(element, "accessibilitySubrole") as? String ?? ""
                        let secure = type == "SecureTextField" || subrole.contains("Secure")
                        let rect = SimulatorAXDelegate.frame(element)
                        let rawValue = secure ? nil : Self.object(element, "accessibilityValue")
                        let value = (rawValue as? String) ?? (rawValue as? NSNumber)?.stringValue
                        elements.append(UIElement(type: type, id: Self.object(element, "accessibilityIdentifier") as? String,
                            label: Self.object(element, "accessibilityLabel") as? String, value: value,
                            enabled: SimulatorAXDelegate.boolean(element, "isAccessibilityEnabled", default: true),
                            frame: .init(x: rect.origin.x, y: rect.origin.y, width: rect.width, height: rect.height), depth: depth))
                        handles.append(element)
                        for child in Self.object(element, "accessibilityChildren") as? [AnyObject] ?? [] {
                            try walk(child, depth: depth + 1)
                            if elements.count >= 500 { truncated = true; break }
                        }
                    }
                    try walk(root, depth: 0)
                    try delegate.check()
                    if let target {
                        let index = try target.index(in: elements)
                        let element = handles[index]
                        if focus {
                            guard ["TextField", "SecureTextField", "TextArea", "SearchField"].contains(elements[index].type) else {
                                throw DeviceHubError.serviceFailed("The selected element is not a text field. Run describe_ui and target a TextField/TextArea")
                            }
                            // AX focus alone can update the accessibility cursor without making
                            // UIKit's field first responder. Use the same activation as a real tap.
                            guard SimulatorAXDelegate.boolean(element, "accessibilityPerformPress", default: false) else {
                                throw DeviceHubError.serviceFailed("The text field did not accept activation. No text was sent; focus it with tap, then retry type_text")
                            }
                        } else {
                            guard SimulatorAXDelegate.boolean(element, "accessibilityPerformPress", default: false) else {
                                throw DeviceHubError.serviceFailed("The element did not accept an accessibility press. Inspect describe_ui/screenshot before retrying; coordinate tap is available")
                            }
                        }
                        try delegate.check()
                    }
                    continuation.resume(returning: UITree(elements: elements, truncated: truncated, coordinateSpace: "accessibility-ui-points"))
                } catch { continuation.resume(throwing: error) }
            }
        }
    }
}

/// Runtime delegate selectors used by Apple's AXPTranslator (see Meta idb's documented bridge).
private final class SimulatorAXDelegate: NSObject {
    private let device: AnyObject
    private let deadline = Date().addingTimeInterval(10)
    private var timedOut = false
    init(device: AnyObject) { self.device = device }

    func check() throws {
        if timedOut || Date() > deadline { throw DeviceHubError.timeout("reading simulator accessibility; retry describe_ui after the app is responsive") }
    }

    private final class Response: @unchecked Sendable {
        let lock = NSLock()
        var value: AnyObject?
    }

    private func callback() -> @convention(block) (AnyObject) -> AnyObject? {
        { [self] request in
            guard !timedOut, Date() < deadline else { timedOut = true; return nil }
            let selector = NSSelectorFromString("sendAccessibilityRequestAsync:completionQueue:completionHandler:")
            guard device.responds(to: selector) else { return nil }
            typealias Send = @convention(c) (AnyObject, Selector, AnyObject, DispatchQueue, (@convention(block) (AnyObject?) -> Void)?) -> Void
            let response = Response(), semaphore = DispatchSemaphore(value: 0)
            unsafeBitCast(device.method(for: selector), to: Send.self)(device, selector, request, DispatchQueue.global(qos: .userInitiated)) { value in
                response.lock.withLock { response.value = value }
                semaphore.signal()
            }
            if semaphore.wait(timeout: .now() + min(3, max(0, deadline.timeIntervalSinceNow))) == .timedOut {
                timedOut = true
                return nil
            }
            return response.lock.withLock { response.value }
        }
    }

    @objc func accessibilityTranslationDelegateBridgeCallbackWithToken(_ token: NSString) -> @convention(block) (AnyObject) -> AnyObject? { callback() }
    @objc func accessibilityTranslationDelegateBridgeCallback() -> @convention(block) (AnyObject) -> AnyObject? { callback() }
    @objc func accessibilityTranslationConvertPlatformFrameToSystem(_ rect: CGRect, withToken token: NSString) -> CGRect { rect }
    @objc func accessibilityTranslationConvertPlatformFrameToSystem(_ rect: CGRect, withContext context: AnyObject?, postProcess: AnyObject?) -> CGRect { rect }
    @objc func accessibilityTranslationRootParentWithToken(_ token: NSString) -> AnyObject? { nil }
    @objc func accessibilityTranslationRootParent() -> AnyObject? { nil }

    static func frame(_ element: AnyObject) -> CGRect {
        let selector = NSSelectorFromString("accessibilityFrame")
        guard element.responds(to: selector) else { return .zero }
        typealias Get = @convention(c) (AnyObject, Selector) -> CGRect
        let frame = unsafeBitCast(element.method(for: selector), to: Get.self)(element, selector)
        return [frame.minX, frame.minY, frame.width, frame.height].allSatisfy(\.isFinite) ? frame : .zero
    }

    static func boolean(_ element: AnyObject, _ name: String, default fallback: Bool) -> Bool {
        let selector = NSSelectorFromString(name)
        guard element.responds(to: selector) else { return fallback }
        typealias Get = @convention(c) (AnyObject, Selector) -> Bool
        return unsafeBitCast(element.method(for: selector), to: Get.self)(element, selector)
    }
}

/// The public `xcrun simctl` tool, used where a stable command exists.
enum SimulatorTools {
    static func developerDirectory() -> String? {
        let environment = ProcessInfo.processInfo.environment["DEVELOPER_DIR"] ?? ""
        let selected = environment.isEmpty ? (try? output(of: "/usr/bin/xcode-select", ["-p"])) : environment
        let candidates = [selected, "/Applications/Xcode.app/Contents/Developer"].compactMap { $0 }
        // The command-line tools alone do not include the simulator frameworks.
        return candidates.first { directory in
            let simulatorKit = URL(fileURLWithPath: directory).deletingLastPathComponent()
                .appendingPathComponent("SharedFrameworks/SimulatorKit.framework").path
            return FileManager.default.fileExists(atPath: simulatorKit)
        }
    }

    /// Runs `simctl` and returns its trimmed standard output.
    @discardableResult
    static func simctl(_ arguments: [String], developerDirectory: String, timeout: Duration? = nil) async throws -> String {
        let data = try await withThrowingTaskGroup(of: Data.self) { group in
            group.addTask {
                try await run("/usr/bin/xcrun", ["simctl"] + arguments, environment: ["DEVELOPER_DIR": developerDirectory])
            }
            if let timeout {
                group.addTask {
                    try await Task.sleep(for: timeout)
                    throw DeviceHubError.serviceFailed("Simulator startup timed out. Try starting it again.")
                }
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func output(of executable: String, _ arguments: [String]) throws -> String? {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    private static func run(_ executable: String, _ arguments: [String], environment: [String: String]) async throws -> Data {
        let process = Process()
        let output = Pipe()
        let errors = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { $1 }
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = errors
        let finished = ProcessTermination(process)
        try Task.checkCancellation()
        try process.run()
        return try await withTaskCancellationHandler {
            // Drain both pipes so a chatty child can never block on a full buffer.
            async let stdout = Task.detached { output.fileHandleForReading.readDataToEndOfFile() }.value
            async let stderr = Task.detached { errors.fileHandleForReading.readDataToEndOfFile() }.value
            let (data, message) = await (stdout, stderr)
            let status = await finished.wait()
            try Task.checkCancellation()
            guard status == 0 else {
                let detail = String(decoding: message, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                throw DeviceHubError.serviceFailed(detail.isEmpty ? "simctl \(arguments.dropFirst().first ?? "") failed" : detail)
            }
            return data
        } onCancel: {
            // Stop only our command-line waiter, never the simulator or CoreSimulatorService.
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
    }
}
