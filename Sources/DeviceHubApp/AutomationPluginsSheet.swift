import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct AutomationPluginsSheet: View {
    @ObservedObject var automation: AutomationModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text("自动化插件").font(.title2.weight(.semibold))
                    Text("插件提供任务、导入方式和运行选项。")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button("安装插件…", action: choosePackage)
                    .buttonStyle(.borderedProminent).disabled(automation.isBusy || !automation.isPrepared)
            }
            Text("Python 插件会在本机执行代码，请安装来自可信作者的插件包。")
                .font(.caption).foregroundStyle(.secondary)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if automation.plugins.isEmpty {
                        ContentUnavailableView("暂无可用插件", systemImage: "puzzlepiece.extension",
                                               description: Text("选择插件文件夹或 ZIP 安装包。"))
                    }
                    ForEach(automation.plugins) { plugin in
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: "puzzlepiece.extension").font(.title2).foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 5) {
                                HStack(spacing: 8) {
                                    Text(plugin.name).font(.headline)
                                    if automation.selectedPluginID == plugin.id {
                                        Text("当前插件").font(.caption).foregroundStyle(Color.accentColor)
                                    }
                                }
                                Text("v\(plugin.version) · \(plugin.location == "bundled" ? "随应用提供" : "已安装")")
                                    .font(.caption).foregroundStyle(.secondary)
                                Text(plugin.description).font(.callout).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("打开插件") {
                                if automation.selectPlugin(plugin.id) { dismiss() }
                            }.disabled(automation.isBusy)
                        }
                        .padding(14)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
                    }
                }
            }
            if let message = automation.pluginMessage {
                Text(message).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
            if let error = automation.libraryError {
                Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled).lineLimit(5)
            }
            Divider()
            HStack {
                Button("打开插件文件夹", action: automation.openPluginsDirectory)
                Button("刷新", action: automation.reloadPlugins).disabled(automation.isBusy)
                if automation.isInstalling || automation.isRefreshingTasks { ProgressView().controlSize(.small) }
                Spacer()
                Button("完成") { dismiss() }.keyboardShortcut(.cancelAction).disabled(automation.isInstalling)
            }
        }
        .padding(24)
        .frame(width: 640, height: 540)
        .interactiveDismissDisabled(automation.isInstalling)
    }

    private func choosePackage() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.zip, .folder]
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
