import SwiftUI

struct MCPActivityPanel: View {
    @ObservedObject var activity: MCPActivityStore

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("MCP 调用记录").font(.headline)
                    Text("全部设备 · 最近 200 条 · 仅本次运行")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button { activity.clear() } label: { Label("清空记录", systemImage: "trash") }
                    .labelStyle(.iconOnly).buttonStyle(.borderless)
                    .help("清空记录，不取消正在执行的调用")
                    .disabled(activity.calls.isEmpty)
            }
            .padding(16)
            Divider()
            if activity.calls.isEmpty {
                ContentUnavailableView("暂无 MCP 调用", systemImage: "terminal",
                    description: Text("Agent 通过 MCP 调用工具后，参数、状态和结果会实时显示在这里。"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(activity.calls) { call in
                            MCPActivityRow(call: call)
                        }
                    }
                    .padding(12)
                }
            }
        }
    }
}

private struct MCPActivityRow: View {
    let call: MCPActivityStore.Call
    @State private var expanded = false

    private var status: String {
        switch call.state {
        case .running: "执行中"
        case .succeeded: "已完成"
        case .failed: "失败"
        }
    }

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 8) {
                Text("参数").font(.caption).foregroundStyle(.secondary)
                detail(call.arguments)
                if call.state != .running {
                    Text(call.state == .failed ? "错误" : "结果").font(.caption).foregroundStyle(.secondary)
                    detail(call.result)
                }
            }
            .padding(.top, 8)
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .top) {
                    Text(call.name).font(.system(.callout, design: .monospaced).weight(.semibold))
                        .lineLimit(2)
                    Spacer(minLength: 4)
                    if call.state == .running { ProgressView().controlSize(.mini) }
                    Text(status).font(.caption)
                        .foregroundStyle(call.state == .failed ? Color.red : Color.secondary)
                }
                Text(call.device).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                HStack {
                    Text(call.startedAt, format: .dateTime.hour().minute().second())
                    if let elapsed = call.elapsed { Text(String(format: "· %.2f 秒", elapsed)) }
                }
                .font(.caption2).foregroundStyle(.secondary)
                if !call.result.isEmpty {
                    Text(call.result).font(.caption).lineLimit(2)
                        .foregroundStyle(call.state == .failed ? Color.red : Color.secondary)
                }
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
    }

    private func detail(_ text: String) -> some View {
        Text(text).font(.system(size: 11, design: .monospaced))
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
