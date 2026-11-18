import Foundation

/// Physical Apple device commands provided by Xcode's CoreDevice service.
public enum IOSDeviceManagement {
    public enum Action: Hashable, Sendable {
        case restart, rename, unpair, collectSysdiagnose, showInFinder, browseSandbox
    }

    /// Uses the host inventory so selection does not open a PhoneUse device session.
    public static func availableActions(for device: DeviceSummary) async -> Set<Action> {
        guard let id = try? identifier(for: device), device.isReady || device.paired == true,
              let list = try? await DeviceCtl.run(["list", "devices"], timeout: 8) else { return [] }
        async let deviceHelp = (try? await DeviceCtl.output(["help", "device"])) ?? ""
        async let infoHelp = (try? await DeviceCtl.output(["help", "device", "info"])) ?? ""
        async let manageHelp = (try? await DeviceCtl.output(["help", "manage"])) ?? ""
        return await actions(for: id, isReady: device.isReady, inventory: list,
                             deviceHelp: deviceHelp, infoHelp: infoHelp, manageHelp: manageHelp)
    }

    static func actions(for id: String, isReady: Bool, inventory: [String: Any],
                        deviceHelp: String, infoHelp: String, manageHelp: String) -> Set<Action> {
        let devices = inventory["devices"] as? [[String: Any]] ?? []
        guard let device = devices.first(where: { row in
            let properties = row["properties"] as? [String: Any]
            let hardware = (properties?["hardware"] ?? row["hardwareProperties"]) as? [String: Any]
            return [row["identifier"], hardware?["udid"]].compactMap { $0 as? String }
                .contains { $0.caseInsensitiveCompare(id) == .orderedSame }
        }) else { return [] }
        let capabilities = (device["capabilities"] as? [[String: Any]] ?? [])
            .compactMap { $0["featureIdentifier"] as? String }
        func hasFeature(_ suffix: String) -> Bool {
            capabilities.contains("com.apple.coredevice.feature." + suffix)
        }
        func hasCommand(_ command: String, in help: String) -> Bool {
            help.split(separator: "\n").contains { $0.split(whereSeparator: \.isWhitespace).first == Substring(command) }
        }

        var actions: Set<Action> = []
        if hasCommand("unpair", in: manageHelp) && hasFeature("unpairdevice") { actions.insert(.unpair) }
        guard isReady else { return actions }
        if hasCommand("reboot", in: deviceHelp) && hasFeature("rebootdevice") { actions.insert(.restart) }
        if hasCommand("rename", in: deviceHelp) && hasFeature("renamedevice") { actions.insert(.rename) }
        if hasCommand("sysdiagnose", in: deviceHelp) && hasFeature("capturesysdiagnose") { actions.insert(.collectSysdiagnose) }
        if hasCommand("mountpoint", in: infoHelp) && hasFeature("filesystemoperation") { actions.insert(.showInFinder) }
        if hasCommand("apps", in: infoHelp) && hasCommand("files", in: infoHelp) { actions.insert(.browseSandbox) }
        return actions
    }

    public static func restart(_ device: DeviceSummary) async throws {
        let id = try identifier(for: device)
        _ = try await DeviceCtl.run(["device", "reboot", "--device", id])
    }

    public static func rename(_ device: DeviceSummary, to name: String) async throws {
        let id = try identifier(for: device)
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw DeviceHubError.serviceFailed("Enter a device name.") }
        _ = try await DeviceCtl.run(["device", "rename", "--device", id, "--name=\(name)"])
        // Ready devices are not continuously probed. Publish the successful change to all clients.
        try await DeviceHub.shared.daemon().deviceRenamed(device.id, name: name)
    }

    public static func unpairFromXcode(_ device: DeviceSummary) async throws {
        let id = try identifier(for: device)
        _ = try await DeviceCtl.run(["manage", "unpair", "--device", id])
    }

    public static func collectSysdiagnose(_ device: DeviceSummary, in folder: URL) async throws {
        let id = try identifier(for: device)
        _ = try await DeviceCtl.run(["device", "sysdiagnose", "--device", id, "--destination", folder.path], timeout: 600)
    }

    public static func directory(for device: DeviceSummary) async throws -> URL {
        let id = try identifier(for: device)
        let result = try await DeviceCtl.run(["device", "info", "mountpoint", "--device", id])
        guard let path = result["dataPath"] as? String, path.hasPrefix("/") else {
            throw DeviceHubError.serviceFailed("Xcode did not return a device mount path.")
        }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    private static func identifier(for device: DeviceSummary) throws -> String {
        guard device.platform == .ios, !device.isSimulator, !device.deviceIdentifier.isEmpty else {
            throw DeviceHubError.capabilityUnavailable("Managing this device through Xcode CoreDevice")
        }
        return device.deviceIdentifier
    }
}
