import PhoneUseKit
import PhoneUseUI
import SwiftUI

/// phone-use's main window: the shared device workspace with developer panels.
struct PhoneUseWindow: View {
    @EnvironmentObject private var model: DeviceListModel
    @AppStorage("inspector.visible") private var showsPanel = true
    @AppStorage("inspector.tab") private var selectedTab = Tab.settings.rawValue

    enum Tab: String, CaseIterable {
        case settings, deviceInfo

        var workspaceTab: WorkspaceTab {
            switch self {
            case .settings: WorkspaceTab(id: rawValue, title: "设备设置", systemImage: "slider.horizontal.3")
            case .deviceInfo: WorkspaceTab(id: rawValue, title: "设备信息", systemImage: "info.circle")
            }
        }
    }

    var body: some View {
        DeviceWorkspace(title: "phone-use", tabs: Tab.allCases.map(\.workspaceTab),
                        selectedTab: $selectedTab, showsPanel: $showsPanel) { tab, screen in
            switch Tab(rawValue: tab.id) ?? .settings {
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
    }
}
