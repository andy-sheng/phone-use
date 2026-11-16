import CoreGraphics
import Foundation
import IOSurface
import ObjectiveC

/// Xcode's simulator frameworks, loaded at runtime so phone-use still starts on Macs without Xcode.
///
/// CoreSimulator finds booted devices and their framebuffer; SimulatorKit builds and sends the
/// same Indigo HID messages Simulator.app uses. Only this file touches the private interfaces.
final class CoreSimulatorBridge: @unchecked Sendable {
    typealias MouseMessage = @convention(c) (UnsafePointer<CGPoint>, UnsafePointer<CGPoint>?, UInt32, UInt,
                                             CGSize, UInt32) -> UnsafeMutableRawPointer?
    typealias ButtonMessage = @convention(c) (UInt32, UInt32, UInt32) -> UnsafeMutableRawPointer?
    typealias ArbitraryMessage = @convention(c) (UInt32, UInt32, UInt32, UInt32) -> UnsafeMutableRawPointer?

    let developerDirectory: String
    let mouseMessage: MouseMessage
    let buttonMessage: ButtonMessage
    let arbitraryMessage: ArbitraryMessage

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
    func mainDisplay(of device: AnyObject) throws -> AnyObject {
        guard let renderable = objc_getProtocol("SimDisplayIOSurfaceRenderable"),
              let io = Self.object(device, "io"),
              let ports = Self.object(io, "ioPorts") as? [AnyObject] else {
            throw DeviceHubError.serviceFailed("CoreSimulator did not list the simulator's displays")
        }
        for port in ports {
            guard let descriptor = Self.object(port, "descriptor"), descriptor.conforms(to: renderable),
                  let state = Self.object(descriptor, "state") else { continue }
            let selector = NSSelectorFromString("displayClass")
            guard state.responds(to: selector) else { continue }
            typealias DisplayClass = @convention(c) (AnyObject, Selector) -> UInt16
            // Display class 0 is the main screen; external displays and CarPlay use others.
            if unsafeBitCast(state.method(for: selector), to: DisplayClass.self)(state, selector) == 0 {
                return descriptor
            }
        }
        throw DeviceHubError.capabilityUnavailable("simulator main display")
    }

    func pointScale(of device: AnyObject) -> Double {
        let type = device.value(forKey: "deviceType") as AnyObject?
        let scale = (type?.value(forKey: "mainScreenScale") as? NSNumber)?.doubleValue ?? 0
        return scale.isFinite && scale > 0 ? scale : 1
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
    static func simctl(_ arguments: [String], developerDirectory: String) async throws -> String {
        let data = try await run("/usr/bin/xcrun", ["simctl"] + arguments, environment: ["DEVELOPER_DIR": developerDirectory])
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
        let finished = AsyncStream<Void> { continuation in
            process.terminationHandler = { _ in continuation.finish() }
        }
        try process.run()
        // Drain both pipes so a chatty child can never block on a full buffer.
        async let stdout = Task.detached { output.fileHandleForReading.readDataToEndOfFile() }.value
        async let stderr = Task.detached { errors.fileHandleForReading.readDataToEndOfFile() }.value
        let (data, message) = await (stdout, stderr)
        for await _ in finished {}
        guard process.terminationStatus == 0 else {
            let detail = String(decoding: message, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw DeviceHubError.serviceFailed(detail.isEmpty ? "simctl \(arguments.dropFirst().first ?? "") failed" : detail)
        }
        return data
    }
}
