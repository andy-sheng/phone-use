import AppKit
import PhoneUseKit

enum MCPManagement: String, CaseIterable {
    case available = "list_management_actions"
    case start = "start_simulator", shutdown = "shutdown_simulator", restart = "restart_device"
    case rename = "rename_device", erase = "erase_simulator", remove = "delete_simulator"
    case finder = "show_device_in_finder", unpair = "unpair_device"
    case sysdiagnose = "collect_sysdiagnose", carPlay = "open_carplay_simulator"

    var description: String {
        switch self {
        case .available: "List management tools available for the specified Apple device in its current state."
        case .start: "Boot a shut down iOS simulator and wait for boot to complete. Discovery may take a moment to update."
        case .shutdown: "Shut down a booted simulator. Ends its preview and active recordings."
        case .restart: "Restart a booted simulator or supported iPhone/iPad. Ends its preview and active recordings."
        case .rename: "Rename the selected simulator or supported iPhone/iPad."
        case .erase: "Erase all apps, content and settings on the explicitly identified simulator."
        case .remove: "Permanently delete the explicitly identified simulator and its data from this Mac."
        case .finder: "Open the selected Apple device's directory in Finder on the host Mac and return its local path."
        case .unpair: "Remove the specified iPhone/iPad's Xcode pairing with this Mac."
        case .sysdiagnose: "Collect sysdiagnose from a supported iPhone/iPad into an existing absolute directory on the Mac. May take several minutes."
        case .carPlay: "Open the installed CarPlay Simulator on the Mac for a ready USB-connected iPhone."
        }
    }

    var disruptive: Bool { [.shutdown, .restart, .erase, .remove, .unpair].contains(self) }
    var needsIdentifier: Bool { [.erase, .remove, .unpair].contains(self) }

    @MainActor static func available(for device: DeviceSummary) async -> Set<Self> {
        if device.isSimulator {
            guard await SimulatorLifecycle.isAvailable(for: device) else { return [] }
            var operations = Set<Self>()
            if device.canStartSimulator { operations.insert(.start) }
            if device.isReady { operations.formUnion([.shutdown, .restart]) }
            if ["Booted", "Shutdown"].contains(device.simulatorState) { operations.formUnion([.rename, .erase, .remove, .finder]) }
            return operations
        }
        guard !device.isAndroid else { return [] }
        let actions = await IOSDeviceManagement.availableActions(for: device)
        let mapping: [IOSDeviceManagement.Action: Self] = [.rename: .rename, .restart: .restart, .unpair: .unpair,
                                                             .collectSysdiagnose: .sysdiagnose, .showInFinder: .finder]
        var operations = Set(actions.compactMap { mapping[$0] })
        if device.isReady, device.isWired, !device.isPad, carPlayURL != nil { operations.insert(.carPlay) }
        return operations
    }

    @MainActor private static var carPlayURL: URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.CarPlaySimulator")
    }

    @MainActor func execute(_ device: DeviceSummary, name: String?, directory: URL?,
                            recordings: MCPRecordings, workspace: MCPWorkspaceAccess?) async throws -> [String: Any] {
        let available = await Self.available(for: device)
        var output: [String: Any] = ["device": device.udid, "operation": rawValue]
        if self == .available {
            output["actions"] = available.map(\.rawValue).sorted()
            return try mcpObject(output)
        }
        guard available.contains(self) else {
            throw ToolFailure(message: "\(rawValue) is unavailable for \(device.name) in state \(device.state.rawValue).")
        }
        if disruptive || self == .start {
            if let movie = try await recordings.finish(for: device.id) { output["saved_recording"] = movie.metadata }
            await workspace?.endPreview(device)
            await DeviceHub.shared.closeSession(for: device.id)
        }
        switch self {
        case .start: try await SimulatorLifecycle.start(device)
        case .shutdown: try await SimulatorLifecycle.shutDown(device)
        case .restart:
            if device.isSimulator { try await SimulatorLifecycle.restart(device) }
            else { try await IOSDeviceManagement.restart(device) }
        case .rename:
            guard let name else { throw ToolFailure(message: "Missing name.") }
            if device.isSimulator { try await SimulatorLifecycle.rename(device, to: name) }
            else { try await IOSDeviceManagement.rename(device, to: name) }
        case .erase: try await SimulatorLifecycle.erase(device)
        case .remove: try await SimulatorLifecycle.remove(device)
        case .unpair: try await IOSDeviceManagement.unpairFromXcode(device)
        case .finder:
            let url = try await device.isSimulator ? SimulatorLifecycle.directory(for: device) : IOSDeviceManagement.directory(for: device)
            guard NSWorkspace.shared.open(url) else { throw ToolFailure(message: "Finder could not open \(url.path).") }
            output["local_path"] = url.path
        case .sysdiagnose:
            var isDirectory: ObjCBool = false
            guard let directory, FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                throw ToolFailure(message: "Choose an existing destination directory on the Mac.")
            }
            try await IOSDeviceManagement.collectSysdiagnose(device, in: directory)
            output["directory"] = directory.path
        case .carPlay:
            guard let url = Self.carPlayURL else { throw ToolFailure(message: "CarPlay Simulator is unavailable.") }
            _ = try await NSWorkspace.shared.openApplication(at: url, configuration: .init())
        case .available: break
        }
        return try mcpObject(output)
    }
}

func mcpObject(_ object: [String: Any]) throws -> [String: Any] {
    let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    return ["content": [mcpText(String(decoding: data, as: UTF8.self))], "structuredContent": object]
}
