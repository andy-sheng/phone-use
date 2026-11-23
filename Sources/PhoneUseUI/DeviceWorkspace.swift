import PhoneUseKit
import SwiftUI

/// One tab of the workspace's side panel. Each app supplies its own tabs and their content.
public struct WorkspaceTab: Identifiable, Hashable, Sendable {
    public let id: String
    public let title: String
    public let systemImage: String

    public init(id: String, title: String, systemImage: String) {
        self.id = id
        self.title = title
        self.systemImage = systemImage
    }
}

/// The shared device window: device sidebar, live screen with its controls, compact mode, and a
/// side panel whose tabs the app provides. Expects a `DeviceListModel` in the environment.
enum PlatformFilter: String {
    case all, apple, android
}

private let zoomSteps: [CGFloat] = [0.25, 0.33, 0.5, 0.67, 0.75, 1, 1.25, 1.5, 2, 3]

public struct DeviceWorkspace<Panel: View>: View {
    @EnvironmentObject private var model: DeviceListModel
    @StateObject private var screen = ScreenModel()
    @State private var search = ""
    @AppStorage("sidebar.platformFilter") private var platformFilter: PlatformFilter = .all
    @AppStorage("sidebar.showsUnavailable") private var showsUnavailable = true
    @State private var newSimulatorFamily: SimulatorCreationSheet.Family?
    @State private var showingPairing = false
    /// Screen points per view point, or nil to fit the window.
    @State private var zoom: CGFloat?
    @State private var fitScale: CGFloat = 1
    @State private var showingLaunch = false
    @State private var bundleID = ""
    @State private var managementAvailability: (key: String, simulator: Bool, physical: Set<IOSDeviceManagement.Action>)?
    @State private var managementPrompt: DeviceManagementRequest?
    @State private var managingDevice: DeviceManagementRequest?
    @State private var managementError: String?
    /// Shows only the device screen in a window fitted to it.
    @State private var isCompact = false
    @State private var compactWindow = CompactWindowController()

    private let title: String
    private let tabs: [WorkspaceTab]
    @Binding private var selectedTab: String
    @Binding private var showsPanel: Bool
    private let allowsInput: Bool
    private let badgedTabs: Set<String>
    private let devicesWithPasscode: Set<String>
    private let configurePasscode: ((DeviceSummary) -> Void)?
    private let browseSandbox: ((DeviceSummary) -> Void)?
    private let panel: (WorkspaceTab, ScreenModel) -> Panel

    /// - Parameters:
    ///   - title: the window title while no device is selected.
    ///   - allowsInput: false while something else drives the selected device, such as a task.
    ///   - badgedTabs: tab IDs whose toolbar button shows an activity dot.
    ///   - panel: the side panel's content for the selected tab.
    public init(title: String, tabs: [WorkspaceTab], selectedTab: Binding<String>, showsPanel: Binding<Bool>,
                allowsInput: Bool = true, badgedTabs: Set<String> = [],
                devicesWithPasscode: Set<String> = [], configurePasscode: ((DeviceSummary) -> Void)? = nil,
                browseSandbox: ((DeviceSummary) -> Void)? = nil,
                @ViewBuilder panel: @escaping (WorkspaceTab, ScreenModel) -> Panel) {
        self.title = title
        self.tabs = tabs
        _selectedTab = selectedTab
        _showsPanel = showsPanel
        self.allowsInput = allowsInput
        self.badgedTabs = badgedTabs
        self.devicesWithPasscode = devicesWithPasscode
        self.configurePasscode = configurePasscode
        self.browseSandbox = browseSandbox
        self.panel = panel
    }

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

    private var canControl: Bool { liveStream != nil && allowsInput && !screen.isChangingGeometry && !isManagingSelection }
    private var isManagingSelection: Bool {
        guard let managingDevice else { return false }
        return managingDevice.device.id == model.selection
    }

    private var managementKey: String {
        guard let device = model.selectedDevice else { return "" }
        return "\(device.id)|\(device.connection)|\(device.state)|\(device.paired == true)"
    }

    /// The system, how the device is connected and, while the screen streams, its frame rate.
    private var windowSubtitle: String {
        guard let device = model.selectedDevice else { return "" }
        let frameRate = liveStream == nil ? nil : screen.framesPerSecond.map { String(format: "%.0f fps", $0) }
        return [device.osDescription, device.connectionDescription, frameRate].compactMap { $0 }.joined(separator: " · ")
    }

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

    public var body: some View {
        // One stable root, so switching layouts keeps the tasks below and the live stream running.
        ZStack {
            if isCompact {
                compactStage
            } else {
                DeviceWorkspaceView(showsPanel: showsPanel) {
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
        .task {
            model.visibleScreen = screen
            defer { if model.visibleScreen === screen { model.visibleScreen = nil } }
            await model.run()
        }
        .task(id: managementKey) { await readManagementAvailability() }
        .task(id: screenKey) {
            await screen.run(device: model.selectedDevice)
        }
        .onChange(of: model.selection) { _, selectedID in
            screen.selectionChanged(to: selectedID)
            zoom = nil
        }
        .onChange(of: model.previewRequest, initial: true) { _, _ in
            if let device = model.consumePreviewRequest() {
                screen.selectionChanged(to: device.id)
                requestPreview(device)
            }
        }
        .sheet(isPresented: $showingPairing) { WirelessPairingSheet() }
        .sheet(item: $newSimulatorFamily) { family in
            SimulatorCreationSheet(family: family) { id in
                if platformFilter == .android { platformFilter = .apple }
                search = ""
                model.selection = id
            }
        }
        .sheet(item: $managementPrompt) { request in
            DeviceManagementPrompt(request) { performManagement(request, name: $0) }
        }
        .alert("设备操作失败", isPresented: Binding(get: { managementError != nil }, set: { if !$0 { managementError = nil } })) {
            Button("好") { managementError = nil }
        } message: {
            Text(managementError ?? "")
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
                ForEach(available) { deviceRow($0) }
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
                    ForEach(unavailable) { deviceRow($0) }
                }
            }
        }
        .searchable(text: $search, placement: .sidebar, prompt: "Search")
        .toolbar {
            ToolbarItemGroup {
                Menu {
                    Button("配对附近设备…") { showingPairing = true }
                    Section("模拟器") {
                        ForEach(SimulatorCreationSheet.Family.allCases) { family in
                            Button(family.rawValue + "…", systemImage: family.icon) { newSimulatorFamily = family }
                                .disabled(!allowsInput)
                        }
                    }
                } label: {
                    Label("添加设备", systemImage: "plus")
                }
                .menuIndicator(.hidden)
                .help("配对附近设备或创建模拟器")
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

    private func deviceRow(_ device: DeviceSummary) -> some View {
        DeviceRow(device: device, hasPasscode: devicesWithPasscode.contains(device.id))
            .contextMenu {
                if let configurePasscode {
                    Button("设置解锁密码…", systemImage: "key") { configurePasscode(device) }
                        .disabled(device.isAndroid && !device.isReady)
                }
                if canRemoveSimulator(device) {
                    managementItem(.remove, device: device, prompts: true, destructive: true)
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
        .navigationTitle(model.selectedDevice?.name ?? title)
        .navigationSubtitle(windowSubtitle)
        .toolbar { detailToolbar }
    }

    @ViewBuilder
    private func deviceStage(compact: Bool) -> some View {
        if let device = model.selectedDevice {
            if let stream = liveStream {
                if compact {
                    DeviceScreenView(screen: screen, stream: stream, allowsInput: allowsInput,
                                     frameStyle: DeviceFrameStyle(device), insets: CompactLayout.screenInsets)
                } else {
                    DeviceScreenView(screen: screen, stream: stream, allowsInput: allowsInput,
                                     frameStyle: DeviceFrameStyle(device),
                                     zoom: zoom, onFitScale: { fitScale = $0 })
                }
            } else if let request = managingDevice, request.device.id == device.id, request.action.interruptsPreview {
                ProgressView(request.action.title)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if !device.isAndroid && (device.isReady || device.canStartSimulator) {
                AppleDeviceStandbyView(device: device,
                                       isConnecting: screen.isShowingDevice(device.id) && screen.isConnecting,
                                       status: screen.isShowingDevice(device.id) ? screen.status : nil,
                                       error: screen.isShowingDevice(device.id) ? screen.connectionError : nil,
                                       connect: { requestPreview(device) },
                                       cancel: { screen.cancelConnection() })
            } else if !device.isReady {
                DeviceSetupView(device: device, pairWirelessly: { showingPairing = true })
                    .padding(compact ? 16 : 24)
            } else {
                DeviceConnectionView(device: device,
                                     isConnecting: screen.isShowingDevice(device.id) && screen.isConnecting,
                                     status: screen.isShowingDevice(device.id) ? screen.status : nil,
                                     error: screen.isShowingDevice(device.id) ? screen.connectionError : nil,
                                     connect: { requestPreview(device) },
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
                Button { zoom = nil } label: { Label("适合窗口", systemImage: "arrow.up.left.and.down.right.magnifyingglass") }
                    .help("适合窗口 (⌘0)")
                    .keyboardShortcut("0", modifiers: .command)
                Button { zoom = 1 } label: { Label("实际大小", systemImage: "1.magnifyingglass") }
                    .help("实际大小 (⌘1)")
                    .keyboardShortcut("1", modifiers: .command)
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
            ForEach(tabs) { inspectorTabToggle($0) }
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
        Menu {
            if let device = model.selectedDevice {
                if device.isAndroid {
                    launchMenuItem
                    Divider()
                    Button("重新连接画面") { Task { await screen.reconnect() } }
                        .disabled(!canControl || screen.isReconnecting)
                    Button("断开连接") { screen.cancelConnection() }.disabled(liveStream == nil)
                } else if device.isSimulator {
                    simulatorMenu(device)
                    Divider()
                    launchMenuItem
                } else {
                    physicalDeviceMenu(device)
                    Divider()
                    launchMenuItem
                }
            }
        } label: {
            Label("更多", systemImage: "ellipsis")
        }
        .menuIndicator(.hidden)
        .help("更多设备操作")
        .disabled(model.selectedDevice == nil)
        .popover(isPresented: $showingLaunch, arrowEdge: .bottom) { launchPopover }
    }

    private var launchMenuItem: some View {
        Button("启动应用…") { showingLaunch = true }.disabled(!canControl)
    }

    @ViewBuilder
    private func simulatorMenu(_ device: DeviceSummary) -> some View {
        if managementAvailability?.key == managementKey && managementAvailability?.simulator == true {
            if device.canStartSimulator {
                previewMenuItem(device, title: "启动模拟器")
            } else if device.isReady {
                managementItem(.shutDown, device: device)
                Divider()
                managementItem(.restart, device: device)
            }
            if canRemoveSimulator(device) {
                Divider()
                managementItem(.showInFinder, device: device)
                managementItem(.rename, device: device, prompts: true)
                Divider()
                managementItem(.erase, device: device, prompts: true, destructive: true)
                Divider()
                managementItem(.remove, device: device, prompts: true, destructive: true)
            }
        }
        if device.isReady {
            Divider()
            previewMenuItem(device)
        }
    }

    @ViewBuilder
    private func physicalDeviceMenu(_ device: DeviceSummary) -> some View {
        let actions = managementAvailability?.key == managementKey ? managementAvailability?.physical ?? [] : []
        let carPlay = device.isReady && device.isWired && !device.isPad && carPlayURL != nil
        if device.isReady { previewMenuItem(device) }
        if actions.contains(.restart) {
            Divider()
            managementItem(.restart, device: device, prompts: true)
        }
        if !actions.isDisjoint(with: [.showInFinder, .rename]) || (actions.contains(.browseSandbox) && browseSandbox != nil) {
            Divider()
            if actions.contains(.showInFinder) { managementItem(.showInFinder, device: device) }
            if actions.contains(.rename) { managementItem(.rename, device: device, prompts: true) }
            if actions.contains(.browseSandbox), let browseSandbox {
                Button("应用沙箱…", systemImage: "folder") { browseSandbox(device) }
                    .disabled(isManagingSelection)
            }
        }
        if carPlay || actions.contains(.collectSysdiagnose) {
            Divider()
            if carPlay { managementItem(.carPlay, device: device) }
            if actions.contains(.collectSysdiagnose) { managementItem(.collectSysdiagnose, device: device, ellipsis: true) }
        }
        if actions.contains(.unpair) {
            Divider()
            managementItem(.unpair, device: device, prompts: true, destructive: true)
        }
    }

    private func previewMenuItem(_ device: DeviceSummary, title: String = "查看屏幕") -> some View {
        let isRequested = screen.requestedDeviceID == device.id && (liveStream != nil || screen.isConnecting)
        return Button(isRequested ? "停止屏幕共享" : title) {
            if isRequested { screen.cancelConnection() } else { requestPreview(device) }
        }
        .disabled(isManagingSelection)
    }

    private func requestPreview(_ device: DeviceSummary) {
        guard managingDevice?.device.id != device.id else { return }
        screen.requestConnection(to: device)
    }

    private func canRemoveSimulator(_ device: DeviceSummary) -> Bool {
        device.isSimulator && ["Booted", "Shutdown"].contains(device.simulatorState)
    }

    private func managementItem(_ action: DeviceManagementAction, device: DeviceSummary,
                                prompts: Bool = false, destructive: Bool = false, ellipsis: Bool = false) -> some View {
        Button(action.title + (prompts || ellipsis ? "…" : ""), role: destructive ? .destructive : nil) {
            let request = DeviceManagementRequest(action: action, device: device)
            if prompts { managementPrompt = request } else { performManagement(request) }
        }
        .disabled(!allowsInput || managingDevice != nil || screen.isConnecting)
    }

    private func readManagementAvailability() async {
        guard let device = model.selectedDevice, !device.isAndroid else { return }
        let key = managementKey
        let simulator = device.isSimulator ? await SimulatorLifecycle.isAvailable(for: device) : false
        let physical = device.isSimulator ? [] : await IOSDeviceManagement.availableActions(for: device)
        guard !Task.isCancelled else { return }
        managementAvailability = (key, simulator, physical)
    }

    private var carPlayURL: URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.CarPlaySimulator")
    }

    private func performManagement(_ request: DeviceManagementRequest, name: String = "") {
        guard allowsInput, managingDevice == nil,
              let device = model.devices.first(where: { $0.id == request.device.id }) else { return }
        // A sidebar context menu can target a row without changing the current selection.
        if request.action == .remove {
            guard canRemoveSimulator(device) else { return }
        } else if device.id != model.selection { return }
        managingDevice = request
        Task {
            defer { managingDevice = nil }
            if request.action.interruptsPreview {
                if screen.requestedDeviceID == device.id { screen.cancelConnection() }
                await DeviceHub.shared.closeSession(for: device.id)
            }
            do {
                switch request.action {
                case .shutDown: try await SimulatorLifecycle.shutDown(device)
                case .restart:
                    if device.isSimulator { try await SimulatorLifecycle.restart(device) }
                    else { try await IOSDeviceManagement.restart(device) }
                case .showInFinder:
                    let folder = try await device.isSimulator ? SimulatorLifecycle.directory(for: device)
                        : IOSDeviceManagement.directory(for: device)
                    guard NSWorkspace.shared.open(folder) else {
                        throw DeviceHubError.serviceFailed("无法在 Finder 中打开设备目录。")
                    }
                case .rename:
                    if device.isSimulator { try await SimulatorLifecycle.rename(device, to: name) }
                    else { try await IOSDeviceManagement.rename(device, to: name) }
                case .erase: try await SimulatorLifecycle.erase(device)
                case .remove:
                    try await SimulatorLifecycle.remove(device)
                    model.didRemoveSimulator(device.id)
                case .unpair:
                    try await IOSDeviceManagement.unpairFromXcode(device)
                    await readManagementAvailability()
                case .collectSysdiagnose:
                    let panel = NSOpenPanel()
                    panel.title = "选择 sysdiagnose 保存目录"
                    panel.canChooseDirectories = true
                    panel.canChooseFiles = false
                    panel.canCreateDirectories = true
                    if await panel.begin() == .OK, let folder = panel.url {
                        try await IOSDeviceManagement.collectSysdiagnose(device, in: folder)
                        NSWorkspace.shared.open(folder)
                    }
                case .carPlay:
                    guard let carPlayURL else { throw DeviceHubError.capabilityUnavailable("CarPlay Simulator") }
                    _ = try await NSWorkspace.shared.openApplication(at: carPlayURL, configuration: .init())
                }
            } catch {
                managementError = "\(request.action.title) · \(device.name)\n\(error)"
            }
        }
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
        .navigationTitle(model.selectedDevice?.name ?? title)
        .navigationSubtitle(windowSubtitle)
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
                    .disabled(liveStream == nil || screen.isChangingGeometry)
                if !isAndroid {
                    ControlBarButton(recordingHelp, systemImage: screen.isRecording ? "stop.circle.fill" : "record.circle") {
                        screen.toggleRecording()
                    }
                    .foregroundStyle(screen.isRecording ? Color.red : Color.primary)
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                    .disabled(screen.isChangingGeometry || (!screen.isRecording && (liveStream == nil || !screen.canRecord)))
                }
            }
            .padding(4)
            .glassCapsule()
            HStack(spacing: 2) {
                if isCompact && (screen.canFold || screen.canRotate) {
                    // Keep all fold presets visible even in the 300-point compact window.
                    Menu {
                        Button("锁定屏幕") { screen.press(.lock) }
                        Button("音量 −") { screen.press(.volumeDown) }
                        Button("音量 +") { screen.press(.volumeUp) }
                        if screen.canRotate {
                            Divider()
                            rotationMenu
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .frame(width: 28, height: 32)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .help("设备操作")
                    .accessibilityLabel("设备操作")
                } else {
                    ControlBarButton("锁定屏幕", systemImage: "lock") { screen.press(.lock) }
                    ControlBarButton("音量 −", systemImage: "speaker.wave.1") { screen.press(.volumeDown) }
                    ControlBarButton("音量 +", systemImage: "speaker.wave.3") { screen.press(.volumeUp) }
                }
            }
            .disabled(!canControl)
            .padding(4)
            .glassCapsule()
            if screen.canRotate && !isCompact {
                ControlBarButton(screen.canFold ? "向右旋转 90°" : "向左旋转 90°",
                                 assetImage: screen.canFold ? "DeviceRotateRight" : "DeviceRotateLeft") {
                    screen.rotate(primaryRotationDirection)
                }
                .accessibilityIdentifier("device.rotate.\(primaryRotationDirection.rawValue)")
                .contextMenu { rotationMenu }
                .disabled(!canControl)
                .padding(4)
                .glassCapsule()
            }
            if screen.canFold {
                HStack(spacing: 2) {
                    postureButton(.closed, title: "折叠", icon: "DuoClosed")
                    postureButton(.partiallyOpen, title: "半开", icon: "DuoHalfOpen")
                    postureButton(.openFlat, title: "展开", icon: "DuoOpen")
                }
                .disabled(!canControl)
                .padding(4)
                .glassCapsule()
            }
        }
    }

    // Match DeviceHub: Duo exposes Rotate Right, while other simulators expose Rotate Left.
    private var primaryRotationDirection: DeviceRotationDirection { screen.canFold ? .right : .left }

    private var rotationMenu: some View {
        let directions: [DeviceRotationDirection] = screen.canFold ? [.right, .left] : [.left, .right]
        return ForEach(directions, id: \.rawValue) { direction in
            Button {
                screen.rotate(direction)
            } label: {
                Label {
                    Text(direction == .right ? "向右旋转 90°" : "向左旋转 90°")
                } icon: {
                    Image(direction == .right ? "DeviceRotateRight" : "DeviceRotateLeft", bundle: .module)
                }
            }
        }
    }

    private func postureButton(_ posture: SimulatorPosture, title: String, icon: String) -> some View {
        ControlBarButton(title, assetImage: icon) { screen.setPosture(posture) }
            .foregroundStyle(screen.posture == posture ? Color.accentColor : Color.primary)
            .accessibilityIdentifier("device.posture.\(posture.rawValue)")
    }

    private var recordingHelp: String {
        if screen.isRecording { return "停止录屏并保存到桌面 (⇧⌘R)" }
        return screen.canRecord ? "录制屏幕 (⇧⌘R)" : "当前连接不支持录屏"
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
        zoom = zoomSteps.first { $0 > current * 1.01 } ?? zoomSteps.last
    }

    private func zoomOut() {
        let current = zoom ?? fitScale
        zoom = zoomSteps.last { $0 < current * 0.99 } ?? zoomSteps.first
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
            if let tab = tabs.first(where: { $0.id == selectedTab }) ?? tabs.first {
                panel(tab, screen)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Selecting a tab shows the inspector; selecting the current tab again hides it.
    private func inspectorTabToggle(_ tab: WorkspaceTab) -> some View {
        let isActive = showsPanel && selectedTab == tab.id
        return Toggle(isOn: Binding(
            get: { isActive },
            set: { on in
                if on {
                    selectedTab = tab.id
                    withAnimation(.smooth(duration: 0.25)) { showsPanel = true }
                } else {
                    withAnimation(.smooth(duration: 0.25)) { showsPanel = false }
                }
            }
        )) {
            Label(tab.title, systemImage: tab.systemImage)
                .overlay(alignment: .topTrailing) {
                    if badgedTabs.contains(tab.id) {
                        Circle().fill(.orange).frame(width: 6, height: 6).offset(x: 4, y: -2)
                    }
                }
        }
        .toggleStyle(.button)
        .labelStyle(.iconOnly)
        .help(isActive ? "隐藏\(tab.title)" : "显示\(tab.title)")
    }
}

private struct ControlBarButton: View {
    let title: String
    let image: Image
    let action: () -> Void

    init(_ title: String, systemImage: String, action: @escaping () -> Void) {
        self.title = title
        self.image = Image(systemName: systemImage)
        self.action = action
    }

    init(_ title: String, assetImage: String, action: @escaping () -> Void) {
        self.title = title
        #if SWIFT_PACKAGE
        self.image = Image(assetImage, bundle: .module).renderingMode(.template)
        #else
        self.image = Image(assetImage).renderingMode(.template)
        #endif
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            image
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
    let hasPasscode: Bool

    var body: some View {
        HStack(spacing: 10) {
            if !device.isAndroid {
                AppleSidebarDeviceIcon(device: device)
            } else {
                Image(systemName: device.deviceIcon)
                    .font(.system(size: 14))
                    .frame(width: 32, height: 32)
                    .background(.quaternary, in: Circle())
                    .foregroundStyle(device.isAttached ? .primary : .tertiary)
            }
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(device.name)
                        .fontWeight(device.isSimulator ? .semibold : .regular)
                        .lineLimit(1)
                    if !device.isSimulator {
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
                }
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(device.isReady || !device.isAttached ? Color.secondary : Color.orange)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if hasPasscode {
                Image(systemName: "key.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help("已保存解锁密码")
                    .accessibilityLabel("已保存解锁密码")
            }
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
        if device.isSimulator { return "Simulator" }
        return switch device.state {
        case .ready where !device.isWired:
            [device.modelName, device.connectionDescription].compactMap { $0 }.joined(separator: " · ")
        case .ready, .disconnected: device.modelName ?? device.connectionDescription
        case .probing: "Checking…"
        case .untrusted: "Not trusted"
        case .unauthorized: "USB debugging not authorized"
        case .offline: "Offline"
        case .developerModeOff: "Developer Mode off"
        case .developerImageMissing: "Preparing developer services"
        case .wirelessPairingExpired: "Wi-Fi pairing expired"
        }
    }
}
