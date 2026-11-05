import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct AutomationPluginsSheet: View {
    @ObservedObject var automation: AutomationModel
    @Environment(\.dismiss) private var dismiss
    @State private var candidateID: String?
    @State private var showsURLInstall = false

    private static let packageType = UTType(exportedAs: "dev.devicehub.plugin", conformingTo: .zip)

    private var canLoad: Bool {
        !automation.isBusy && candidateID != automation.selectedPluginID
            && automation.plugins.contains { $0.id == candidateID }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text("选择插件").font(.title2.weight(.semibold))
                    Text("一次只加载一个插件，任务和配置按插件保留。")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Menu("安装插件") {
                    Button("从插件文件安装…", action: choosePackage)
                    Button("从 URL 安装…") { showsURLInstall = true }
                }
                .disabled(automation.isBusy || !automation.isPrepared)
            }
            Text("Python 插件会在本机执行代码，请安装来自可信作者的插件包。")
                .font(.caption).foregroundStyle(.secondary)
            Divider()
            if automation.plugins.isEmpty {
                ContentUnavailableView("暂无可用插件", systemImage: "puzzlepiece.extension",
                                       description: Text("安装 .dhplugin 插件文件，或输入插件包的下载 URL。"))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(automation.plugins) { plugin in
                            Button { candidateID = plugin.id } label: {
                                HStack(alignment: .top, spacing: 12) {
                                    Image(systemName: candidateID == plugin.id ? "largecircle.fill.circle" : "circle")
                                        .font(.title3)
                                        .foregroundStyle(candidateID == plugin.id ? Color.accentColor : .secondary)
                                    VStack(alignment: .leading, spacing: 5) {
                                        HStack(spacing: 8) {
                                            Text(plugin.name).font(.headline)
                                            if automation.selectedPluginID == plugin.id {
                                                Text("已加载").font(.caption).foregroundStyle(Color.accentColor)
                                            }
                                        }
                                        Text("v\(plugin.version) · \(plugin.location == "bundled" ? "随应用提供" : "已安装")")
                                            .font(.caption).foregroundStyle(.secondary)
                                        Text(plugin.description).font(.callout).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                }
                                .padding(14)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                                .background(candidateID == plugin.id ? Color.accentColor.opacity(0.09) : Color.secondary.opacity(0.06),
                                            in: RoundedRectangle(cornerRadius: 10))
                            }
                            .buttonStyle(.plain)
                            .disabled(automation.isBusy)
                            .accessibilityLabel("选择插件：\(plugin.name)")
                            .accessibilityAddTraits(candidateID == plugin.id ? [.isSelected] : [])
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            if let message = automation.pluginMessage {
                Text(message).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
            if let error = automation.pluginInstallError {
                Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled).lineLimit(5)
            }
            if let error = automation.libraryError {
                Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled).lineLimit(5)
            }
            if let current = automation.selectedPlugin, candidateID != current.id {
                Text("加载后将关闭\(current.name)，其任务和配置会保留。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Divider()
            HStack {
                Button("打开插件文件夹", action: automation.openPluginsDirectory)
                Button("刷新", action: automation.reloadPlugins).disabled(automation.isBusy)
                if automation.isInstalling || automation.isRefreshingTasks { ProgressView().controlSize(.small) }
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction).disabled(automation.isInstalling)
                Button(candidateID != nil && candidateID == automation.selectedPluginID ? "当前已加载" : "加载所选插件") {
                    if let candidateID, automation.loadPlugin(candidateID) { dismiss() }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!canLoad)
            }
        }
        .padding(24)
        .frame(width: 640, height: 540)
        .interactiveDismissDisabled(automation.isInstalling)
        .sheet(isPresented: $showsURLInstall) { AutomationPluginInstallSheet(automation: automation) }
        .onAppear { candidateID = automation.selectedPluginID ?? automation.plugins.first?.id }
        .onChange(of: automation.plugins.map(\.id)) { _, ids in
            if candidateID == nil || !ids.contains(candidateID!) {
                candidateID = automation.selectedPluginID ?? ids.first
            }
        }
    }

    private func choosePackage() {
        let panel = NSOpenPanel()
        panel.title = "安装 DeviceHub 插件"
        panel.message = "选择 .dhplugin 插件文件，也支持 ZIP 安装包。"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [Self.packageType, .zip]
        panel.prompt = "安装插件"
        if let window = NSApp.keyWindow {
            panel.beginSheetModal(for: window) { response in
                if response == .OK, let url = panel.url { automation.installPlugin(url) }
            }
        } else {
            panel.begin { response in
                if response == .OK, let url = panel.url { automation.installPlugin(url) }
            }
        }
    }
}
