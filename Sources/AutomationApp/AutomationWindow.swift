import PhoneUseKit
import PhoneUseUI
import SwiftUI

/// automation's main window: the shared device workspace with plugin and task panels.
struct AutomationWindow: View {
    @EnvironmentObject private var model: DeviceListModel
    @ObservedObject var automation: AutomationModel
    @AppStorage("inspector.visible") private var showsPanel = true
    @AppStorage("inspector.tab") private var selectedTab = Tab.automation.rawValue
    @State private var presentedSheet: TaskSheet?

    enum Tab: String, CaseIterable {
        case automation, library, deviceInfo

        var workspaceTab: WorkspaceTab {
            switch self {
            case .automation: WorkspaceTab(id: rawValue, title: "插件", systemImage: "puzzlepiece.extension")
            case .library: WorkspaceTab(id: rawValue, title: "任务库", systemImage: "doc.text")
            case .deviceInfo: WorkspaceTab(id: rawValue, title: "设备信息", systemImage: "info.circle")
            }
        }
    }

    private enum TaskSheet: String, Identifiable {
        case importTask, plugins
        var id: String { rawValue }
    }

    /// The preview stays view-only while a task drives the selected device.
    private var allowsInput: Bool {
        !automation.isRunning || automation.isProbe || automation.runDevice?.id != model.selectedDevice?.id
    }

    var body: some View {
        DeviceWorkspace(title: "automation", tabs: Tab.allCases.map(\.workspaceTab),
                        selectedTab: $selectedTab, showsPanel: $showsPanel, allowsInput: allowsInput,
                        badgedTabs: automation.isRunning ? [Tab.automation.rawValue] : []) { tab, screen in
            panel(Tab(rawValue: tab.id) ?? .automation, screen: screen)
        }
        .sheet(item: $presentedSheet) { sheet in
            switch sheet {
            case .importTask: AutomationImportSheet(automation: automation)
            case .plugins: AutomationPluginsSheet(automation: automation)
            }
        }
        .onChange(of: automation.importGeneration) { _, _ in show(.automation) }
        .onChange(of: automation.openGeneration) { _, _ in show(.automation) }
        .onChange(of: automation.selectedPluginID) { _, _ in
            if selectedTab == Tab.library.rawValue { selectedTab = Tab.automation.rawValue }
        }
    }

    @ViewBuilder
    private func panel(_ tab: Tab, screen: ScreenModel) -> some View {
        switch tab {
        case .automation:
            AutomationPanel(device: model.selectedDevice, automation: automation,
                            openLibrary: { selectedTab = Tab.library.rawValue },
                            managePlugins: { presentedSheet = .plugins })
        case .library:
            if automation.selectedPlugin != nil {
                AutomationLibraryPage(automation: automation,
                                      open: { _ = automation.openTask($0) },
                                      importTask: { presentedSheet = .importTask },
                                      back: { selectedTab = Tab.automation.rawValue })
            } else {
                ContentUnavailableView("尚未加载插件", systemImage: "puzzlepiece.extension",
                                       description: Text("加载插件后即可浏览它的任务。"))
            }
        case .deviceInfo:
            if let device = model.selectedDevice {
                DeviceInspector(device: device, screen: screen)
            } else {
                ContentUnavailableView("未选择设备", systemImage: "iphone")
            }
        }
    }

    private func show(_ tab: Tab) {
        selectedTab = tab.rawValue
        withAnimation(.smooth(duration: 0.25)) { showsPanel = true }
    }
}
