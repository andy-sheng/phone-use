import SwiftUI

struct AutomationPluginInstallSheet: View {
    @ObservedObject var automation: AutomationModel
    @Environment(\.dismiss) private var dismiss
    @State private var source = ""
    @FocusState private var sourceFocused: Bool

    private var trimmedSource: String { source.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var isValidURL: Bool {
        guard let components = URLComponents(string: trimmedSource),
              let scheme = components.scheme?.lowercased(), ["https", "http"].contains(scheme),
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil, components.url != nil else { return false }
        return trimmedSource.rangeOfCharacter(from: .whitespacesAndNewlines.union(.controlCharacters)) == nil
    }
    private var canInstall: Bool { isValidURL && automation.isPrepared && !automation.isBusy }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Text("从 URL 安装插件").font(.title2.weight(.semibold))
                Text("输入 .dhplugin 或 ZIP 插件包的直接下载地址。")
                    .font(.callout).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 8) {
                TextField("https://example.com/my-plugin.dhplugin", text: $source)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("插件下载 URL")
                    .focused($sourceFocused)
                    .disabled(automation.isInstalling)
                    .onSubmit(install)
                if !trimmedSource.isEmpty && !isValidURL {
                    Text("请输入完整的 HTTP 或 HTTPS 地址，不要包含用户名、密码或空白字符。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text("安装后仍需在插件列表中选择并加载。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let message = automation.pluginMessage {
                HStack(alignment: .top, spacing: 8) {
                    if automation.isInstalling { ProgressView().controlSize(.small) }
                    Text(message).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
            if let error = automation.pluginInstallError {
                Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled)
            }
            HStack {
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction).disabled(automation.isInstalling)
                Button(automation.isInstalling ? "正在安装…" : "下载并安装", action: install)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(!canInstall)
            }
        }
        .padding(24)
        .frame(width: 500)
        .interactiveDismissDisabled(automation.isInstalling)
        .onAppear {
            automation.preparePluginInstall()
            sourceFocused = true
        }
        .onChange(of: automation.installGeneration) { _, _ in dismiss() }
    }

    private func install() {
        guard canInstall else { return }
        automation.installPlugin(fromURL: trimmedSource)
    }
}
