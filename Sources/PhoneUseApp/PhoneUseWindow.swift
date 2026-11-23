import PhoneUseKit
import PhoneUseUI
import SwiftUI

/// phone-use's main window: the shared device workspace with developer panels.
struct PhoneUseWindow: View {
    @EnvironmentObject private var activity: MCPActivityStore
    @EnvironmentObject private var model: DeviceListModel
    @AppStorage("inspector.visible") private var showsPanel = true
    @AppStorage("inspector.tab") private var selectedTab = Tab.uiTree.rawValue
    @State private var credentialStates: [String: UnlockCredential.Status] = [:]
    @State private var credentialRevision = 0
    @State private var passcodeDevice: DeviceSummary?
    @State private var filesDevice: DeviceSummary?

    enum Tab: String, CaseIterable {
        case uiTree, calls, settings, deviceInfo

        var workspaceTab: WorkspaceTab {
            switch self {
            case .uiTree: WorkspaceTab(id: rawValue, title: "界面结构", systemImage: "list.bullet.indent")
            case .calls: WorkspaceTab(id: rawValue, title: "调用记录", systemImage: "terminal")
            case .settings: WorkspaceTab(id: rawValue, title: "设备设置", systemImage: "slider.horizontal.3")
            case .deviceInfo: WorkspaceTab(id: rawValue, title: "设备信息", systemImage: "info.circle")
            }
        }
    }

    var body: some View {
        DeviceWorkspace(title: "PhoneUse", tabs: Tab.allCases.map(\.workspaceTab),
                        selectedTab: $selectedTab, showsPanel: $showsPanel,
                        devicesWithPasscode: Set(credentialStates.filter { $0.value.hasPIN }.keys),
                        configurePasscode: { passcodeDevice = $0 },
                        browseSandbox: { filesDevice = $0 }) { tab, screen in
            switch Tab(rawValue: tab.id) ?? .settings {
            case .uiTree:
                DeviceUIOutlinePanel(device: model.selectedDevice, screen: screen)
            case .calls:
                MCPActivityPanel(activity: activity)
            case .settings:
                VStack(spacing: 0) {
                    if let device = model.selectedDevice {
                        DeviceUnlockPanel(device: device, credentialStatus: credentialStates[device.id]) {
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
        .task(id: credentialRevision) {
            let statuses = try? await DeviceUnlockController.shared.statuses(for: model.devices)
            guard !Task.isCancelled else { return }
            credentialStates = statuses ?? [:]
        }
        .sheet(item: $passcodeDevice) { device in
            DevicePasscodeSheet(device: device, hasPasscode: credentialStates[device.id]?.hasPIN == true) {
                credentialRevision += 1
            }
        }
        .sheet(item: $filesDevice) { DeviceFilesPanel(device: $0) }
        .onAppear { if selectedTab == "files" { selectedTab = Tab.uiTree.rawValue } }
    }
}
