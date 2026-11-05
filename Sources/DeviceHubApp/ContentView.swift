import DeviceHubKit
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var automation: AutomationModel
    @StateObject private var screen = ScreenModel()
    @State private var search = ""
    @State private var trailingPanel: TrailingPanel? = .automation
    @State private var presentedSheet: TaskSheet?

    private enum TaskSheet: String, Identifiable {
        case library, importTask, plugins
        var id: String { rawValue }
    }

    private enum TrailingPanel {
        case automation, deviceInfo
    }

    /// The screen restarts only when the device changes, switches link or becomes (un)ready, not on
    /// every status update.
    private var screenKey: String {
        guard let device = model.selectedDevice else { return "" }
        return "\(device.udid)|\(device.connection)|\(device.isReady)|\(screen.reconnectGeneration)"
    }

    private func matching(_ devices: [DeviceSummary]) -> [DeviceSummary] {
        let needle = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return devices }
        return devices.filter {
            $0.name.lowercased().contains(needle)
                || ($0.modelName?.lowercased().contains(needle) ?? false)
                || $0.platformName.lowercased().contains(needle)
                || $0.deviceIdentifier.lowercased().contains(needle)
        }
    }

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            HSplitView {
                detail
                    .frame(minWidth: 300, maxWidth: .infinity, maxHeight: .infinity)
                if trailingPanel != nil {
                    Group {
                        switch trailingPanel {
                        case .automation:
                            AutomationPanel(device: model.selectedDevice, automation: automation,
                                            importTask: { presentedSheet = .importTask }, openLibrary: { presentedSheet = .library },
                                            managePlugins: { presentedSheet = .plugins },
                                            close: { trailingPanel = nil })
                        case .deviceInfo:
                            if let device = model.selectedDevice {
                                DeviceInspector(device: device, screen: screen)
                            }
                        case nil:
                            EmptyView()
                        }
                    }
                    .frame(minWidth: 340, idealWidth: 480, maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .task { await model.run() }
        .task(id: screenKey) {
            if let device = model.selectedDevice {
                await screen.run(device: device)
            }
        }
        .frame(minWidth: 940, minHeight: 680)
        .sheet(item: $presentedSheet) { sheet in
            switch sheet {
            case .library: AutomationLibrarySheet().environmentObject(automation)
            case .importTask: AutomationImportSheet(automation: automation)
            case .plugins: AutomationPluginsSheet(automation: automation)
            }
        }
        .onChange(of: automation.importGeneration) { _, _ in
            trailingPanel = .automation
        }
        .onChange(of: automation.openGeneration) { _, _ in trailingPanel = .automation }
    }

    private var sidebar: some View {
        List(selection: $model.selection) {
            let available = matching(model.availableDevices)
            let unavailable = matching(model.unavailableDevices)
            Section("Available") {
                ForEach(available) { DeviceRow(device: $0) }
                if available.isEmpty {
                    Text("Connect an iPhone, iPad or Android device with a USB cable")
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
        .navigationSplitViewColumnWidth(min: 220, ideal: 250)
    }

    private var detail: some View {
        ZStack {
            Color(nsColor: .underPageBackgroundColor)
                .extendedUnderSidebar()
                .ignoresSafeArea()
            if let device = model.selectedDevice, !device.isReady {
                DeviceSetupView(device: device)
                    .padding(24)
            } else if let stream = screen.stream {
                DeviceScreenView(screen: screen, stream: stream,
                                 allowsInput: !automation.isRunning || automation.isProbe || automation.runDevice?.id != model.selectedDevice?.id)
            } else {
                placeholder
            }
        }
        .navigationTitle(model.selectedDevice?.name ?? "phone-use")
        .navigationSubtitle(model.selectedDevice?.osDescription ?? "")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    trailingPanel = trailingPanel == .automation ? nil : .automation
                } label: {
                    Label("插件", systemImage: "sidebar.right")
                        .foregroundStyle(trailingPanel == .automation ? Color.accentColor : .primary)
                        .overlay(alignment: .topTrailing) {
                            if automation.isRunning {
                                Circle().fill(.orange).frame(width: 6, height: 6).offset(x: 4, y: -2)
                            }
                        }
                }
                .help(trailingPanel == .automation ? "收起插件面板" : "显示插件面板")
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    trailingPanel = trailingPanel == .deviceInfo ? nil : .deviceInfo
                } label: {
                    Label("Device Info", systemImage: "info.circle")
                }
                .disabled(model.selectedDevice == nil)
            }
        }
    }

    private var placeholder: some View {
        VStack(spacing: 14) {
            if screen.status != nil {
                ProgressView().controlSize(.large)
            } else {
                Image(systemName: model.selectedDevice?.deviceIcon ?? "smartphone")
                    .font(.system(size: 54, weight: .thin))
                    .foregroundStyle(.secondary)
            }
            Text(model.selectedDevice?.name ?? "No Device")
                .font(.title3.weight(.semibold))
            Text(screen.status ?? model.errorMessage ?? "Connect an iPhone, iPad or Android device with a USB cable.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
        }
        .padding(32)
        .glassCard(cornerRadius: 24)
    }
}

private struct DeviceRow: View {
    let device: DeviceSummary

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: device.deviceIcon)
                .font(.system(size: 15))
                .frame(width: 28, height: 28)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
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
