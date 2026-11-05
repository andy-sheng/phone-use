import AppKit
import SwiftUI

struct AutomationConsole: View {
    @ObservedObject var automation: AutomationModel
    @Binding var autoScroll: Bool
    let collapse: () -> Void

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    private var output: AttributedString {
        var result = AttributedString()
        for entry in automation.logs {
            var timestamp = AttributedString(Self.timeFormatter.string(from: entry.date) + "  ")
            timestamp.foregroundColor = .secondary
            var message = AttributedString("[\(entry.level.rawValue)] \(entry.message)\n")
            switch entry.level {
            case .info: message.foregroundColor = .primary
            case .warning: message.foregroundColor = .orange
            case .error: message.foregroundColor = .red
            case .success: message.foregroundColor = .green
            }
            result += timestamp
            result += message
        }
        return result
    }

    var body: some View {
        VStack(spacing: 0) {
            AutomationConsoleHeader(count: automation.logs.count, expanded: true, toggle: collapse)
            Divider()
            ScrollViewReader { scroll in
                GeometryReader { geometry in
                    ScrollView([.vertical, .horizontal]) {
                        VStack(alignment: .leading, spacing: 0) {
                            if automation.logs.isEmpty {
                                Text("等待任务输出…")
                                    .foregroundStyle(.tertiary)
                            } else {
                                Text(output)
                                    .textSelection(.enabled)
                                    .fixedSize(horizontal: true, vertical: true)
                            }
                            Color.clear.frame(width: 1, height: 1).id("console-end")
                        }
                        .font(.system(size: 11.5, design: .monospaced))
                        .lineSpacing(3)
                        .padding(10)
                        .frame(minWidth: geometry.size.width, minHeight: geometry.size.height, alignment: .topLeading)
                    }
                }
                .onChange(of: automation.logs.last?.id) { _, _ in
                    if autoScroll { scroll.scrollTo("console-end", anchor: .bottomLeading) }
                }
                .onChange(of: autoScroll) { _, enabled in
                    if enabled { scroll.scrollTo("console-end", anchor: .bottomLeading) }
                }
                .onAppear {
                    if autoScroll { scroll.scrollTo("console-end", anchor: .bottomLeading) }
                }
            }
            .background(Color(nsColor: .textBackgroundColor))
            .contextMenu { consoleMenu }
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    @ViewBuilder
    private var consoleMenu: some View {
        Toggle("自动滚动", isOn: $autoScroll)
        Button("清空面板日志") { automation.clearVisibleLogs() }
            .disabled(automation.logs.isEmpty)
        if automation.outputDirectory != nil || automation.screenshot != nil { Divider() }
        if let directory = automation.outputDirectory {
            Button("打开日志文件夹") { NSWorkspace.shared.open(directory) }
        }
        if let screenshot = automation.screenshot {
            Button("查看结果画面") { NSWorkspace.shared.open(screenshot) }
        }
    }
}

struct AutomationConsoleHeader: View {
    let count: Int
    let expanded: Bool
    let toggle: () -> Void

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "terminal").foregroundStyle(.secondary)
            Text("运行日志").fontWeight(.medium)
            if count > 0 { Text("\(count)").monospacedDigit().foregroundStyle(.secondary) }
            Spacer()
            Button(action: toggle) {
                Image(systemName: expanded ? "chevron.down" : "chevron.up")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .accessibilityLabel(expanded ? "收起日志面板" : "展开日志面板")
            .help(expanded ? "收起日志面板" : "展开日志面板")
        }
        .font(.system(size: 11))
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(Color(nsColor: .controlBackgroundColor))
    }
}
