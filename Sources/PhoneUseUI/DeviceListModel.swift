import PhoneUseKit
import Foundation

@MainActor
public final class DeviceListModel: ObservableObject {
    @Published public private(set) var devices: [DeviceSummary] = []
    @Published public var selection: DeviceSummary.ID? {
        didSet {
            if selection != oldValue {
                selectionGeneration = UUID()
                previewRequest = nil
            }
        }
    }
    /// Consumed by a workspace when visible; retained while the app has no window.
    @Published private(set) var previewRequest: DeviceSummary.ID?
    private var selectionGeneration = UUID()
    private var connections: [String: (id: UUID, task: Task<Void, Error>)] = [:]
    private let connectSession: @MainActor (DeviceSummary) async throws -> Void
    @Published public private(set) var errorMessage: String?
    @Published private(set) var actionInProgress: String?
    @Published var actionError: String?

    public let launcher = DaemonLauncher()

    public convenience init() {
        self.init(connectSession: { device in
            await prepareScreenSession(for: device)
            _ = try await DeviceHub.shared.session(for: device.udid)
        })
    }

    init(connectSession: @escaping @MainActor (DeviceSummary) async throws -> Void) {
        self.connectSession = connectSession
    }

    /// Select without opening a session, even if the device needs onboarding.
    public func selectDevice(_ device: DeviceSummary) {
        if let index = devices.firstIndex(where: { $0.id == device.id }) { devices[index] = device }
        else { devices.append(device) }
        selection = device.id
    }

    /// Explicit connection shared by app integrations. A successful open requests the UI preview;
    /// changing selection while connecting must not switch the user back when the open finishes.
    public func connectDevice(_ device: DeviceSummary) async throws {
        guard device.isReady else {
            throw DeviceHubError.deviceNotReady("\(device.name) is not ready (\(device.state.rawValue))")
        }
        selectDevice(device)
        let generation = selectionGeneration
        let connection: (id: UUID, task: Task<Void, Error>)
        if let current = connections[device.id] { connection = current }
        else {
            connection = (UUID(), Task { try await connectSession(device) })
            connections[device.id] = connection
        }
        defer {
            if connections[device.id]?.id == connection.id { connections[device.id] = nil }
        }
        try await connection.task.value
        try Task.checkCancellation()
        guard generation == selectionGeneration, selection == device.id else {
            throw DeviceHubError.deviceNotReady("Selection changed while connecting to \(device.name); select the device and connect again.")
        }
        previewRequest = device.id
    }

    func consumePreviewRequest() -> DeviceSummary? {
        defer { previewRequest = nil }
        guard let previewRequest, selection == previewRequest,
              let device = selectedDevice, device.isReady else { return nil }
        return device
    }

    public var selectedDevice: DeviceSummary? {
        devices.first { $0.id == selection }
    }

    var availableDevices: [DeviceSummary] { devices.filter(\.isAvailable) }
    var unavailableDevices: [DeviceSummary] { devices.filter { !$0.isAvailable } }

    /// Starts the daemon and mirrors its device list, reconnecting if the daemon restarts.
    public func run() async {
        while !Task.isCancelled {
            do {
                try await launcher.start()
                errorMessage = nil
                for await update in try await DeviceHub.shared.deviceUpdates() {
                    apply(update)
                }
                errorMessage = "Lost the connection to the \(PhoneUseConfiguration.current.displayName) daemon. Reconnecting…"
            } catch {
                errorMessage = "\(error)"
            }
            try? await Task.sleep(for: .seconds(2))
        }
    }

    func apply(_ update: [DeviceSummary]) {
        devices = update.sorted { ($0.isAvailable ? 0 : 1, $0.name) < ($1.isAvailable ? 0 : 1, $1.name) }
        // Keep an existing target through discovery gaps. MCP must not silently operate on a
        // different device after the selected one disappears.
        if selection == nil {
            selection = devices.first(where: \.isReady)?.id ?? devices.first(where: \.isAttached)?.id ?? devices.first?.id
        }
    }

    func didRemoveSimulator(_ id: String) {
        if selection == id { selection = nil }
        apply(devices.filter { $0.id != id })
    }

    func selectPairedDevice(_ udid: String?) async {
        guard let udid else { return }
        do {
            apply(try await DeviceHub.shared.devices())
            if devices.contains(where: { $0.udid == udid }) { selection = udid }
        } catch {
            actionError = "\(error)"
        }
    }

    /// Runs one onboarding step for the selected device, surfacing failures in the setup view.
    func perform(_ title: String, _ action: @escaping (String) async throws -> Void) {
        guard let udid = selection, actionInProgress == nil else { return }
        actionInProgress = title
        actionError = nil
        Task {
            do {
                try await action(udid)
            } catch {
                actionError = "\(error)"
            }
            actionInProgress = nil
        }
    }

    public func stop() {
        launcher.stop()
    }
}
