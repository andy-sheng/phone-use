import PhoneUseKit
import PhoneUseUI
import SwiftUI

/// phone-use's main window: the shared device workspace with developer panels.
struct PhoneUseWindow: View {
    @EnvironmentObject private var activity: MCPActivityStore
    @EnvironmentObject private var model: DeviceListModel
    @AppStorage("inspector.visible") private var showsPanel = true
    @AppStorage("inspector.tab") private var selectedTab = Tab.uiTree.rawValue
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
                        browseSandbox: { filesDevice = $0 }) { tab, screen in
            switch Tab(rawValue: tab.id) ?? .settings {
            case .uiTree:
                DeviceUIOutlinePanel(device: model.selectedDevice, screen: screen)
            case .calls:
                MCPActivityPanel(activity: activity)
            case .settings:
                DeviceSettingsPanel(device: model.selectedDevice)
            case .deviceInfo:
                if let device = model.selectedDevice {
                    DeviceInspector(device: device, screen: screen)
                } else {
                    ContentUnavailableView("未选择设备", systemImage: "iphone")
                }
            }
        }
        .sheet(item: $filesDevice) { DeviceFilesPanel(device: $0) }
        .onAppear { if selectedTab == "files" { selectedTab = Tab.uiTree.rawValue } }
    }
}
