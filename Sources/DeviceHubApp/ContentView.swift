import DeviceHubKit
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var automation: AutomationModel
    @StateObject private var screen = ScreenModel()
    @State private var search = ""
    @AppStorage("inspector.visible") private var showsInspector = true
    @AppStorage("inspector.tab") private var inspectorTab: InspectorTab = .automation
    @AppStorage("sidebar.platformFilter") private var platformFilter: PlatformFilter = .all
    @AppStorage("sidebar.showsUnavailable") private var showsUnavailable = true
    @State private var presentedSheet: TaskSheet?
    /// Screen points per view point, or nil to fit the window.
    @State private var zoom: CGFloat?
    @State private var fitScale: CGFloat = 1
    @State private var showingLaunch = false
    @State private var bundleID = ""
    /// Shows only the device screen in a window fitted to it.
    @State private var isCompact = false
    @State private var compactWindow = CompactWindowController()

    private enum TaskSheet: String, Identifiable {
        case importTask, plugins, wirelessPairing
        var id: String { rawValue }
    }

    enum InspectorTab: String, CaseIterable, Identifiable {
        case settings, automation, library, deviceInfo
        var id: String { rawValue }

        var title: String {
            switch self {
            case .settings: "设备设置"
            case .automation: "插件"
            case .library: "任务库"
            case .deviceInfo: "设备信息"
            }
        }

        var systemImage: String {
            switch self {
            case .settings: "slider.horizontal.3"
            case .automation: "puzzlepiece.extension"
            case .library: "doc.text"
            case .deviceInfo: "info.circle"
            }
        }
    }

    enum PlatformFilter: String {
        case all, apple, android
    }

    private static let zoomSteps: [CGFloat] = [0.25, 0.33, 0.5, 0.67, 0.75, 1, 1.25, 1.5, 2, 3]

    /// The screen restarts only when the device changes, switches link or becomes (un)ready, not on
    /// every status update.
    private var screenKey: String {
        guard let device = model.selectedDevice else { return "" }
        return "\(device.udid)|\(device.connection)|\(device.isReady)|\(screen.requestedDeviceID ?? "")|\(screen.reconnectGeneration)"
    }

    private var liveStream: (any ScreenStream)? {
        guard let device = model.selectedDevice, device.isReady, screen.requestedDeviceID == device.id,
              screen.isShowingDevice(device.id) else { return nil }
        return screen.stream
    }

    private var allowsInput: Bool {
        !automation.isRunning || automation.isProbe || automation.runDevice?.id != model.selectedDevice?.id
    }

    private var canControl: Bool { liveStream != nil && allowsInput }

    private var isFiltering: Bool { platformFilter != .all || !showsUnavailable }

    private func matching(_ devices: [DeviceSummary]) -> [DeviceSummary] {
        let needle = search.trimmingCharacters(in: .whitespaces).lowercased()
        return devices.filter { device in
            switch platformFilter {
            case .all: break
            case .apple: if device.isAndroid { return false }
            case .android: if !device.isAndroid { return false }
            }
            guard !needle.isEmpty else { return true }
            return device.name.lowercased().contains(needle)
                || (device.modelName?.lowercased().contains(needle) ?? false)
                || device.platformName.lowercased().contains(needle)
                || device.deviceIdentifier.lowercased().contains(needle)
        }
    }

    var body: some View {
        // One stable root, so switching layouts keeps the tasks below and the live stream running.
        ZStack {
            if isCompact {
                compactStage
            } else {
                DeviceWorkspaceView(showsPanel: showsInspector) {
                    sidebar
                } detail: {
                    detail
                } panel: {
                    inspector
                }
            }
        }
        .background(WindowReader { compactWindow.window = $0 })
        .onChange(of: screen.aspectRatio) { _, ratio in
            if isCompact { compactWindow.fit(screenAspectRatio: ratio) }
        }
        .task { await model.run() }
        .task(id: screenKey) {
            await screen.run(device: model.selectedDevice)
        }
        .onChange(of: model.selection) { _, selectedID in
            screen.selectionChanged(to: selectedID)
            zoom = nil
        }
        .sheet(item: $presentedSheet) { sheet in
            switch sheet {
            case .importTask: AutomationImportSheet(automation: automation)
            case .plugins: AutomationPluginsSheet(automation: automation)
            case .wirelessPairing: WirelessPairingSheet()
            }
        }
        .onChange(of: automation.importGeneration) { _, _ in show(.automation) }
        .onChange(of: automation.openGeneration) { _, _ in show(.automation) }
        .onChange(of: automation.selectedPluginID) { _, _ in
            if inspectorTab == .library { inspectorTab = .automation }
        }
        .onChange(of: allowsInput) { _, enabled in
            if !enabled { showingLaunch = false }
        }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        List(selection: $model.selection) {
            let available = matching(model.availableDevices)
            let unavailable = showsUnavailable ? matching(model.unavailableDevices) : []
            Section("Available") {
                ForEach(available) { DeviceRow(device: $0) }
                if available.isEmpty {
                    Text(isFiltering || !search.isEmpty
                         ? "没有符合条件的设备"
                         : "Connect a device with USB, or use + to pair a nearby iPhone / iPad")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            if !unavailable.isEmpty {
                Section("Unavailable") {
                    ForEach(unavailable) { DeviceRow(device: $0) }
                }
            }
        }
        .searchable(text: $search, placement: .sidebar, prompt: "Search")
        .toolbar {
            ToolbarItemGroup {
                Button { presentedSheet = .wirelessPairing } label: {
                    Label("配对附近设备", systemImage: "plus")
                }
                .help("通过 Wi-Fi 配对附近的 iPhone 或 iPad")
                Menu {
                    Picker("平台", selection: $platformFilter) {
                        Text("全部设备").tag(PlatformFilter.all)
                        Text("iPhone 与 iPad").tag(PlatformFilter.apple)
                        Text("Android").tag(PlatformFilter.android)
                    }
                    .pickerStyle(.inline)
                    Divider()
                    Toggle("显示不可用的设备", isOn: $showsUnavailable)
                } label: {
                    Label("筛选", systemImage: isFiltering
                          ? "line.3.horizontal.decrease.circle.fill"
                          : "line.3.horizontal.decrease.circle")
                }
                .menuIndicator(.hidden)
                .help("筛选设备")
            }
        }
    }

    // MARK: Detail

    private var detail: some View {
        ZStack {
            Color(nsColor: .underPageBackgroundColor)
                .extendedUnderSidebar()
                .ignoresSafeArea()
            deviceStage(compact: false)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if liveStream != nil {
                controlBar
                    .padding(.top, 8)
                    .padding(.bottom, 16)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.smooth(duration: 0.25), value: liveStream != nil)
        // A transparent title bar, so the stage and the device run beneath the toolbar.
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .navigationTitle(model.selectedDevice?.name ?? "phone-use")
        .navigationSubtitle(model.selectedDevice?.osDescription ?? "")
        .toolbar { detailToolbar }
    }

    @ViewBuilder
    private func deviceStage(compact: Bool) -> some View {
        if let device = model.selectedDevice {
            if !device.isReady {
                DeviceSetupView(device: device)
                    .padding(compact ? 16 : 24)
            } else if let stream = liveStream {
                if compact {
                    DeviceScreenView(screen: screen, stream: stream, allowsInput: allowsInput,
                                     frameStyle: DeviceFrameStyle(device), insets: CompactLayout.screenInsets)
                } else {
                    DeviceScreenView(screen: screen, stream: stream, allowsInput: allowsInput,
                                     frameStyle: DeviceFrameStyle(device),
                                     zoom: zoom, onFitScale: { fitScale = $0 })
                }
            } else {
                DeviceConnectionView(device: device,
                                     isConnecting: screen.isShowingDevice(device.id) && screen.isConnecting,
                                     status: screen.isShowingDevice(device.id) ? screen.status : nil,
                                     error: screen.isShowingDevice(device.id) ? screen.connectionError : nil,
                                     connect: { screen.requestConnection(to: device) },
                                     cancel: { screen.cancelConnection() })
            }
        } else {
            placeholder
        }
    }

    @ToolbarContentBuilder
    private var detailToolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Group {
                Button(action: zoomOut) { Label("缩小", systemImage: "minus.magnifyingglass") }
                    .help("缩小 (⌘-)")
                    .keyboardShortcut("-", modifiers: .command)
                Button { zoom = 1 } label: { Label("实际大小", systemImage: "1.magnifyingglass") }
                    .help("实际大小 (⌘1)")
                    .keyboardShortcut("1", modifiers: .command)
                Button { zoom = nil } label: { Label("适合窗口", systemImage: "arrow.up.left.and.down.right.magnifyingglass") }
                    .help("适合窗口 (⌘0)")
                    .keyboardShortcut("0", modifiers: .command)
                Button(action: zoomIn) { Label("放大", systemImage: "plus.magnifyingglass") }
                    .help("放大 (⌘+)")
                    .keyboardShortcut("=", modifiers: .command)
            }
            .disabled(liveStream == nil)
        }

        groupSpacer

        ToolbarItemGroup(placement: .primaryAction) {
            compactToggle
            moreMenu
        }

        groupSpacer

        ToolbarItemGroup(placement: .primaryAction) {
            ForEach(InspectorTab.allCases) { inspectorTabToggle($0) }
        }
    }

    private var compactToggle: some View {
        Button { setCompact(!isCompact) } label: {
            if isCompact {
                Label("显示完整窗口", systemImage: "arrow.up.left.and.arrow.down.right")
            } else {
                Label("仅显示屏幕", systemImage: "arrow.down.right.and.arrow.up.left")
            }
        }
        .help(isCompact ? "显示完整窗口 (⇧⌘M)" : "仅显示设备屏幕 (⇧⌘M)")
        .keyboardShortcut("m", modifiers: [.command, .shift])
        .disabled(!isCompact && model.selectedDevice == nil)
    }

    /// Less frequent device actions, shared by the full and compact toolbars.
    private var moreMenu: some View {
        let isAndroid = model.selectedDevice?.isAndroid ?? false
        return Menu {
            Button("启动应用…") { showingLaunch = true }.disabled(!canControl)
            Divider()
            if isAndroid {
                Button("重新连接画面") { Task { await screen.reconnect() } }
                    .disabled(!canControl || screen.isReconnecting)
            }
            Button("断开连接") { screen.cancelConnection() }
                .disabled(liveStream == nil)
        } label: {
            Label("更多", systemImage: "ellipsis")
        }
        .menuIndicator(.hidden)
        .help("更多设备操作")
        .popover(isPresented: $showingLaunch, arrowEdge: .bottom) { launchPopover }
    }

    private func setCompact(_ compact: Bool) {
        guard compact != isCompact else { return }
        showingLaunch = false
        isCompact = compact
        let controller = compactWindow
        let ratio = screen.aspectRatio
        // Resize once SwiftUI has swapped the layout, so the window takes the new minimum size.
        DispatchQueue.main.async {
            if compact {
                controller.enter(screenAspectRatio: ratio)
            } else {
                controller.exit()
            }
        }
    }

    // MARK: Compact

    /// Only the device, its title and the essential controls, like Simulator's compact window.
    private var compactStage: some View {
        ZStack {
            Color(nsColor: .underPageBackgroundColor)
                .ignoresSafeArea()
            VStack(spacing: 0) {
                deviceStage(compact: true)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                controlBar
                    .opacity(liveStream == nil ? 0 : 1)
                    .frame(height: CompactLayout.controlsHeight)
            }
        }
        .frame(minWidth: CompactLayout.minimumSize.width, minHeight: CompactLayout.minimumSize.height - 60)
        .navigationTitle(model.selectedDevice?.name ?? "phone-use")
        .navigationSubtitle(model.selectedDevice?.osDescription ?? "")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                compactToggle
                moreMenu
            }
        }
    }

    /// Device buttons floating below the screen in two glass capsules, shared by both layouts:
    /// navigation and capture, then the hardware side buttons.
    private var controlBar: some View {
        let isAndroid = model.selectedDevice?.isAndroid ?? false
        return HStack(spacing: 10) {
            HStack(spacing: 2) {
                Group {
                    if isAndroid {
                        ControlBarButton("返回", systemImage: "chevron.backward") { screen.press(.back) }
                    }
                    ControlBarButton("主屏幕 (⇧⌘H)", systemImage: isAndroid ? "circle" : "circle.grid.3x3.fill") {
                        screen.press(.home)
                    }
                    .keyboardShortcut("h", modifiers: [.command, .shift])
                    if isAndroid {
                        ControlBarButton("最近使用的应用", systemImage: "square.on.square") { screen.press(.appSwitch) }
                    }
                }
                .disabled(!canControl)
                ControlBarButton("保存截图到桌面 (⌘S)", systemImage: "camera.viewfinder") { screen.saveScreenshot() }
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled(liveStream == nil)
                if !isAndroid {
                    ControlBarButton(recordingHelp, systemImage: screen.isRecording ? "stop.circle.fill" : "record.circle") {
                        screen.toggleRecording()
                    }
                    .foregroundStyle(screen.isRecording ? Color.red : Color.primary)
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                    .disabled(!screen.isRecording && (liveStream == nil || !screen.canRecord))
                }
            }
            .padding(4)
            .glassCapsule()
            HStack(spacing: 2) {
                ControlBarButton("锁定屏幕", systemImage: "lock") { screen.press(.lock) }
                ControlBarButton("音量 −", systemImage: "speaker.wave.1") { screen.press(.volumeDown) }
                ControlBarButton("音量 +", systemImage: "speaker.wave.3") { screen.press(.volumeUp) }
            }
            .disabled(!canControl)
            .padding(4)
            .glassCapsule()
        }
    }

    private var recordingHelp: String {
        if screen.isRecording { return "停止录屏并保存到桌面 (⇧⌘R)" }
        return screen.canRecord ? "录制屏幕 (⇧⌘R)" : "录屏需要 Xcode"
    }

    /// Separates toolbar groups into their own glass capsules on macOS 26.
    @ToolbarContentBuilder
    private var groupSpacer: some ToolbarContent {
        if #available(macOS 26.0, *) {
            ToolbarSpacer(.fixed, placement: .primaryAction)
        }
    }

    private var launchPopover: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Launch App").font(.headline)
            TextField(screen.isAndroid ? "Package name, e.g. com.android.settings" : "Bundle identifier, e.g. com.apple.Preferences", text: $bundleID)
                .textFieldStyle(.roundedBorder)
                .frame(width: 300)
                .onSubmit(launch)
            HStack {
                Spacer()
                Button("Launch", action: launch)
                    .glassButton(prominent: true)
                    .disabled(bundleID.trimmingCharacters(in: .whitespaces).isEmpty)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
    }

    private func launch() {
        guard canControl else { return }
        screen.launchApp(bundleID: bundleID.trimmingCharacters(in: .whitespaces))
        showingLaunch = false
    }

    private func zoomIn() {
        let current = zoom ?? fitScale
        zoom = Self.zoomSteps.first { $0 > current * 1.01 } ?? Self.zoomSteps.last
    }

    private func zoomOut() {
        let current = zoom ?? fitScale
        zoom = Self.zoomSteps.last { $0 < current * 0.99 } ?? Self.zoomSteps.first
    }

    private var placeholder: some View {
        VStack(spacing: 14) {
            if screen.status != nil {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: "iphone")
                    .font(.system(size: 52, weight: .ultraLight))
                    .foregroundStyle(.tertiary)
            }
            Text("No Device")
                .font(.title3.weight(.semibold))
            Text(screen.status ?? model.errorMessage ?? "Connect a device with USB, or use + in the sidebar to pair an iPhone / iPad over Wi-Fi.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
        }
        .padding(32)
        .glassCard(cornerRadius: 28)
    }

    // MARK: Inspector

    private var inspector: some View {
        // Keep one panel child while switching tabs, so the panel does not animate in again
        // with each page's view identity.
        VStack(spacing: 0) {
            switch inspectorTab {
            case .automation:
                AutomationPanel(device: model.selectedDevice, automation: automation,
                                openLibrary: { inspectorTab = .library },
                                managePlugins: { presentedSheet = .plugins })
            case .library:
                if automation.selectedPlugin != nil {
                    AutomationLibraryPage(automation: automation,
                                          open: { _ = automation.openTask($0) },
                                          importTask: { presentedSheet = .importTask },
                                          back: { inspectorTab = .automation })
                } else {
                    ContentUnavailableView("尚未加载插件", systemImage: "puzzlepiece.extension",
                                           description: Text("加载插件后即可浏览它的任务。"))
                }
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
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Selecting a tab shows the inspector; selecting the current tab again hides it.
    private func inspectorTabToggle(_ tab: InspectorTab) -> some View {
        let isActive = showsInspector && inspectorTab == tab
        return Toggle(isOn: Binding(
            get: { isActive },
            set: { on in
                if on { show(tab) } else { withAnimation(.smooth(duration: 0.25)) { showsInspector = false } }
            }
        )) {
            Label(tab.title, systemImage: tab.systemImage)
                .overlay(alignment: .topTrailing) {
                    if tab == .automation && automation.isRunning {
                        Circle().fill(.orange).frame(width: 6, height: 6).offset(x: 4, y: -2)
                    }
                }
        }
        .toggleStyle(.button)
        .labelStyle(.iconOnly)
        .help(isActive ? "隐藏\(tab.title)" : "显示\(tab.title)")
    }

    private func show(_ tab: InspectorTab) {
        inspectorTab = tab
        withAnimation(.smooth(duration: 0.25)) { showsInspector = true }
    }
}

private struct ControlBarButton: View {
    let title: String
    let systemImage: String
    let action: () -> Void

    init(_ title: String, systemImage: String, action: @escaping () -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 15, weight: .medium))
                .frame(width: 36, height: 32)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(title)
        .accessibilityLabel(title)
    }
}

private struct DeviceRow: View {
    let device: DeviceSummary

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: device.deviceIcon)
                .font(.system(size: 14))
                .frame(width: 30, height: 30)
                .background(.quaternary, in: Circle())
                .foregroundStyle(device.isAttached ? .primary : .tertiary)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(device.name)
                        .lineLimit(1)
                    Image(device.isAndroid ? "PlatformAndroid" : "PlatformApple", bundle: platformIconBundle)
                        .resizable()
                        .renderingMode(.template)
                        .scaledToFit()
                        .frame(width: 14, height: 14)
                        .foregroundStyle(.secondary)
                        .help(device.platformName)
                        .accessibilityLabel(device.platformName)
                        .fixedSize()
                }
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(device.isReady || !device.isAttached ? Color.secondary : Color.orange)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            Text(device.productVersion ?? "")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 3)
        .tag(device.id)
    }

    private var platformIconBundle: Bundle {
        #if SWIFT_PACKAGE
        .module
        #else
        .main
        #endif
    }

    private var subtitle: String {
        switch device.state {
        case .ready where !device.isWired:
            [device.modelName, device.connectionDescription].compactMap { $0 }.joined(separator: " · ")
        case .ready, .disconnected: device.modelName ?? device.connectionDescription
        case .probing: "Checking…"
        case .untrusted: "Not trusted"
        case .unauthorized: "USB debugging not authorized"
        case .offline: "Offline"
        case .developerModeOff: "Developer Mode off"
        case .developerImageMissing: "Preparing developer services"
        }
    }
}
