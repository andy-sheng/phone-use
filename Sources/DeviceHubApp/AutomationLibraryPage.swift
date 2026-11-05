import SwiftUI

struct AutomationLibraryPage: View {
    @ObservedObject var automation: AutomationModel
    let open: (AutomationTask) -> Void
    let importTask: () -> Void
    @State private var search = ""

    private var pluginTasks: [AutomationTask] { automation.visibleTasks }
    private var matches: [AutomationTask] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return pluginTasks }
        return pluginTasks.filter {
            ($0.title + $0.metadata.subtitle + $0.metadata.author + $0.metadata.source)
                .localizedCaseInsensitiveContains(query)
        }
    }
    private var builtInTasks: [AutomationTask] { matches.filter(\.isBuiltIn) }
    private var importedTasks: [AutomationTask] { matches.filter { !$0.isBuiltIn } }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("\(automation.selectedPluginTitle) · 共 \(pluginTasks.count) 项任务")
                    .font(.callout).foregroundStyle(.secondary)
                Spacer()
                if !search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text("找到 \(matches.count) 项").font(.caption).foregroundStyle(.secondary)
                }
            }
            TextField("搜索\(automation.selectedPluginTitle)的任务", text: $search).textFieldStyle(.roundedBorder)
            if automation.isRunning {
                Text("当前任务正在运行，停止后可切换到其他任务。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if matches.isEmpty {
                ContentUnavailableView {
                    Label(pluginTasks.isEmpty ? "\(automation.selectedPluginTitle)暂无任务" : "没有匹配的任务", systemImage: "tray")
                } description: {
                    if pluginTasks.isEmpty {
                        Text(automation.selectedPlugin == nil ? "选择已安装的插件后查看任务。" :
                             (automation.selectedPlugin?.imports.isEmpty == false ? "此插件导入的任务会保存在这里。" : "此插件尚未提供内置任务。"))
                    } else {
                        Text("在\(automation.selectedPluginTitle)中换个名称、作者或任务编号搜索。")
                    }
                } actions: {
                    if pluginTasks.isEmpty && automation.canImport { Button("导入任务", action: importTask) }
                }
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        if !builtInTasks.isEmpty {
                            taskSection("内置任务", tasks: builtInTasks)
                        }
                        if !importedTasks.isEmpty {
                            taskSection("已导入任务", tasks: importedTasks)
                        }
                    }
                }
            }
            if let error = automation.taskLibraryError {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onChange(of: automation.selectedPluginID) { _, _ in search = "" }
    }

    @ViewBuilder
    private func taskSection(_ title: String, tasks: [AutomationTask]) -> some View {
        Text("\(title) · \(tasks.count)")
            .font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.top, 4)
        ForEach(tasks) { item in
            HStack(spacing: 12) {
                Image(systemName: item.isBuiltIn ? "square.stack.3d.up" : "doc.text")
                    .font(.title3).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 5) {
                    Text(item.title).font(.callout.weight(.semibold)).lineLimit(2)
                    if !item.metadata.subtitle.isEmpty {
                        Text(item.metadata.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    if !item.metadata.author.isEmpty {
                        Text(item.metadata.author).font(.caption2).foregroundStyle(.secondary)
                    }
                    if automation.selectedTaskID == item.id {
                        Text("当前任务").font(.caption2).foregroundStyle(Color.accentColor)
                    }
                }
                Spacer(minLength: 4)
                Button("打开") { open(item) }
                    .disabled(automation.isInstalling || automation.isImporting || automation.isRefreshingTasks || (automation.isRunning && automation.selectedTaskID != item.id))
                    .accessibilityLabel("打开任务：\(item.title)")
                if !item.isBuiltIn {
                    Button { automation.removeTask(item) } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless).foregroundStyle(.secondary)
                        .disabled(automation.isBusy)
                        .accessibilityLabel("删除任务：\(item.title)")
                        .help("从此插件的任务库移至废纸篓")
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
        }
    }
}
