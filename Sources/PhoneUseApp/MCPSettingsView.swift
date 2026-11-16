import AppKit
import SwiftUI

/// Tracks whether each client's CLI is installed and already points at this `phone-use-mcp`.
@MainActor
final class MCPClientInstaller: ObservableObject {
    typealias Client = MCPClientSetup.Client

    enum Status: Equatable {
        case checking
        case toolMissing
        case notAdded
        case added
        /// Configured under the same name, but for another copy of phone-use (or an old path).
        case addedElsewhere
        case working
    }

    struct State: Equatable {
        var status: Status = .checking
        var message: String?
        var failed = false
    }

    let setup: MCPClientSetup?
    @Published private(set) var states: [Client: State] = [:]
    private let searchPath: () async -> [String]
    private var path: [String] = []

    init(setup: MCPClientSetup? = MCPClientSetup.serverURL().map { MCPClientSetup(serverPath: $0.path) },
         searchPath: @escaping () async -> [String] = { await CommandLineTools.searchPath() }) {
        self.setup = setup
        self.searchPath = searchPath
    }

    func state(_ client: Client) -> State {
        states[client] ?? State()
    }

    func refresh() async {
        guard setup != nil else { return }
        path = await searchPath()
        await withTaskGroup(of: Void.self) { group in
            for client in Client.allCases {
                group.addTask { await self.refresh(client) }
            }
        }
    }

    /// Adds the server, replacing an entry of the same name so an old path gets updated.
    func add(_ client: Client) async {
        guard let setup, let tool = tool(client) else { return }
        states[client] = State(status: .working)
        _ = await CommandLineTools.run(tool, setup.removeArguments(client), path: path)
        let result = await CommandLineTools.run(tool, setup.addArguments(client), path: path)
        await refresh(client)
        if result.succeeded {
            states[client]?.message = "已添加。在 \(client.title) 中新开会话即可使用 phone-use 工具。"
        } else {
            let detail = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
            states[client]?.message = "添加失败：\(detail.isEmpty ? "退出码 \(result.status)" : detail)"
            states[client]?.failed = true
        }
    }

    private func refresh(_ client: Client) async {
        guard let setup else { return }
        guard let tool = tool(client) else {
            states[client] = State(status: .toolMissing)
            return
        }
        let result = await CommandLineTools.run(tool, setup.getArguments(client), path: path)
        let status: Status = !result.succeeded ? .notAdded
            : setup.describesThisServer(result.output) ? .added : .addedElsewhere
        states[client] = State(status: status)
    }

    private func tool(_ client: Client) -> URL? {
        CommandLineTools.locate(client.executableName, in: path)
    }
}

/// Settings › AI 助手: how to connect MCP clients, following Xcode's Intelligence settings.
struct MCPSettingsView: View {
    @StateObject private var installer: MCPClientInstaller

    init() {
        _installer = StateObject(wrappedValue: MCPClientInstaller())
    }

    init(installer: MCPClientInstaller) {
        _installer = StateObject(wrappedValue: installer)
    }

    var body: some View {
        Form {
            Section {
                Text("让 Claude Code、Codex 等 AI 编程助手通过 MCP 查看和操作已连接的设备。助手第一次调用工具时，phone-use 会在后台自动启动；新设备需要先在主窗口完成配对等准备。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let setup = installer.setup {
                    LabeledContent("MCP 服务") {
                        CopyableText(setup.serverPath)
                    }
                } else {
                    Label("找不到 phone-use-mcp，请重新安装 phone-use。", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            } header: {
                Text("Model Context Protocol")
            }

            if let setup = installer.setup {
                ForEach(MCPClientSetup.Client.allCases) { client in
                    Section(client.title) {
                        ClientRow(client: client, state: installer.state(client)) {
                            Task { await installer.add(client) }
                        }
                        VStack(alignment: .leading, spacing: 6) {
                            Text("终端命令").font(.caption).foregroundStyle(.secondary)
                            CopyableText(setup.shellCommand(client))
                        }
                    }
                }
                Section("其他客户端") {
                    Text("Claude Desktop、Cursor 等使用 JSON 配置的客户端，在其 MCP 配置中加入：")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    CopyableText(setup.jsonConfiguration)
                }
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 560, idealWidth: 620, minHeight: 480, idealHeight: 640)
        .task { await installer.refresh() }
    }
}

private struct ClientRow: View {
    let client: MCPClientSetup.Client
    let state: MCPClientInstaller.State
    let add: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                status
                Spacer()
                switch state.status {
                case .notAdded:
                    Button("添加到 \(client.title)", action: add)
                case .addedElsewhere:
                    Button("更新", action: add)
                case .added:
                    Button("重新添加", action: add)
                case .checking, .toolMissing, .working:
                    EmptyView()
                }
            }
            if let message = state.message {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(state.failed ? .orange : .secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder private var status: some View {
        switch state.status {
        case .checking:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("正在检查…").foregroundStyle(.secondary)
            }
        case .working:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("正在添加…").foregroundStyle(.secondary)
            }
        case .toolMissing:
            Label("未找到 \(client.executableName) 命令。安装 \(client.title) 后可一键添加，也可以在终端运行下面的命令。",
                  systemImage: "questionmark.circle")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        case .notAdded:
            Label("未添加", systemImage: "circle")
                .foregroundStyle(.secondary)
        case .added:
            Label("已添加", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .addedElsewhere:
            Label("已添加，但指向其他位置的 phone-use", systemImage: "exclamationmark.circle.fill")
                .foregroundStyle(.orange)
        }
    }
}

/// Monospaced, selectable text with a copy button.
private struct CopyableText: View {
    let value: String
    @State private var copied = false

    init(_ value: String) {
        self.value = value
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(value)
                .font(.system(.callout, design: .monospaced))
                .multilineTextAlignment(.leading)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            Button(copied ? "已复制" : "复制") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(value, forType: .string)
                copied = true
                Task {
                    try? await Task.sleep(for: .seconds(1.5))
                    copied = false
                }
            }
            .controlSize(.small)
        }
    }
}

/// App menu entry for the MCP settings, next to the standard Settings item.
struct MCPSetupCommands: Commands {
    @Environment(\.openSettings) private var openSettings

    var body: some Commands {
        CommandGroup(after: .appSettings) {
            Button("连接 AI 助手…") { openSettings() }
        }
    }
}
