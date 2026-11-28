import PhoneUseKit
import PhoneUseUI
import SwiftUI

/// phone-use's main window: the shared device workspace with developer panels.
struct PhoneUseWindow: View {
    @ObservedObject var webInspector: WebInspectorWindow
    @Environment(\.openWindow) private var openWindow
    @EnvironmentObject private var activity: MCPActivityStore
    @EnvironmentObject private var model: DeviceListModel
    @AppStorage("inspector.visible") private var showsSidePanel = true
    @State private var showsWebPanel = false
    @AppStorage("inspector.tab") private var selectedTab = Tab.uiTree.rawValue
    @State private var credentialStates: [String: UnlockCredential.Status] = [:]
    @State private var credentialRevision = 0
    @State private var passcodeDevice: DeviceSummary?
    @State private var filesDevice: DeviceSummary?

    @StateObject private var network = SimulatorNetworkSession()

    enum Tab: String, CaseIterable {
        case uiTree, web, network, calls, settings, deviceInfo

        func workspaceTab(webDetached: Bool) -> WorkspaceTab {
            switch self {
            case .uiTree: WorkspaceTab(id: rawValue, title: "界面结构", systemImage: "list.bullet.indent")
            case .web: WorkspaceTab(id: rawValue, title: "网页调试", systemImage: "safari", placement: webDetached ? .window : .bottom)
            case .network: WorkspaceTab(id: rawValue, title: "网络请求", systemImage: "network")
            case .calls: WorkspaceTab(id: rawValue, title: "调用记录", systemImage: "terminal")
            case .settings: WorkspaceTab(id: rawValue, title: "设备设置", systemImage: "slider.horizontal.3")
            case .deviceInfo: WorkspaceTab(id: rawValue, title: "设备信息", systemImage: "info.circle")
            }
        }
    }

    private var panelVisibility: Binding<Bool> {
        Binding {
            selectedTab == Tab.web.rawValue ? showsWebPanel : showsSidePanel
        } set: { visible in
            if selectedTab == Tab.web.rawValue { showsWebPanel = visible }
            else { showsSidePanel = visible }
        }
    }

    var body: some View {
        DeviceWorkspace(title: "PhoneUse", tabs: Tab.allCases.map { $0.workspaceTab(webDetached: webInspector.isDetached) },
                        selectedTab: $selectedTab, showsPanel: panelVisibility,
                        showPanelWindow: webInspector.show,
                        devicesWithPasscode: Set(credentialStates.filter { $0.value.hasPIN }.keys),
                        configurePasscode: { passcodeDevice = $0 },
                        unlockDevice: { device in
                            defer { credentialRevision += 1 }
                            return try await DeviceUnlockController.shared.unlock(device, requireConfiguration: true)
                        },
                        browseSandbox: { filesDevice = $0 }) { tab, screen in
            switch Tab(rawValue: tab.id) ?? .settings {
            case .uiTree:
                DeviceUIOutlinePanel(device: model.selectedDevice, screen: screen)
            case .web:
                WebInspectorDock(presentation: webInspector, model: model) {
                    selectedTab = Tab.web.rawValue
                    showsWebPanel = true
                    openWindow(id: PhoneUseMacApp.mainWindowID)
                }
            case .network:
                if let device = model.selectedDevice, device.platform == .ios, !device.isSimulator, device.isReady {
                    PhysicalNetworkConditionPanel(device: device).id(device.id)
                } else {
                    SimulatorNetworkPanel(monitor: network, device: model.selectedDevice)
                }
            case .calls:
                MCPActivityPanel(activity: activity)
            case .settings:
                VStack(spacing: 0) {
                    if let device = model.selectedDevice {
                        DeviceUnlockPanel(device: device, credentialStatus: credentialStates[device.id],
                                          editPasscode: { passcodeDevice = device }) {
                            credentialRevision += 1
                        }
                        .id(device.id)
                        Divider()
                    }
                    if model.selectedDevice?.isAndroid == true {
                        Spacer()
                    } else {
                        DeviceSettingsPanel(device: model.selectedDevice)
                    }
                }
            case .deviceInfo:
                if let device = model.selectedDevice {
                    DeviceInspector(device: device, screen: screen)
                } else {
                    ContentUnavailableView("未选择设备", systemImage: "iphone")
                }
            }
        }
        .onChange(of: model.devices.map { "\($0.id)|\($0.state.rawValue)" }, initial: true) {
            credentialRevision += 1
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            credentialRevision += 1
        }
        .onChange(of: model.selectedDevice?.isReady == true ? model.selectedDevice?.id : nil) {
            network.endSelection()
        }
        .onDisappear { network.endSelection() }
        .task(id: credentialRevision) {
            let statuses = try? await DeviceUnlockController.shared.statuses(for: model.devices)
            guard !Task.isCancelled else { return }
            credentialStates = statuses ?? [:]
        }
        .sheet(item: $passcodeDevice) { device in
            DevicePasscodeSheet(device: device, status: credentialStates[device.id]) {
                credentialRevision += 1
            }
        }
        .sheet(item: $filesDevice) { DeviceFilesPanel(device: $0) }
        .onAppear { if selectedTab == "files" { selectedTab = Tab.uiTree.rawValue } }
    }
}
