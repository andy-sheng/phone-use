import SwiftUI

struct AutomationLibraryPage: View {
    @ObservedObject var automation: AutomationModel
    let open: (AutomationTask) -> Void
    let importTask: () -> Void
    let back: () -> Void
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
        VStack(spacing: 0) {
            HStack {
                Button(action: back) { Label("返回插件", systemImage: "chevron.left") }
                Spacer()
                Button(action: importTask) { Label("导入任务", systemImage: "plus") }
                    .disabled(!automation.canImport)
            }
            .padding(.horizontal, 16)
            .frame(height: 56)
            Divider()
            libraryContent
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .onChange(of: automation.selectedPluginID) { _, _ in search = "" }
    }

    private var libraryContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("\(automation.selectedPluginTitle) · 任务库").font(.title3.weight(.semibold))
                Text("打开任务后返回主面板，不会自动运行。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            TextField("搜索任务名称、作者或编号", text: $search)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("搜索当前插件的任务")
            HStack(alignment: .firstTextBaseline) {
                Text(search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                     ? "共 \(pluginTasks.count) 项任务" : "找到 \(matches.count) 项任务")
                Spacer()
                if automation.isRunning { Text("运行中仅可浏览") }
            }
            .font(.caption).foregroundStyle(.secondary)
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
                            taskSection("已导入", tasks: importedTasks)
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
                    .disabled(automation.isBusy)
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
            .background(automation.selectedTaskID == item.id ? Color.accentColor.opacity(0.09) : Color.secondary.opacity(0.06),
                        in: RoundedRectangle(cornerRadius: 10))
        }
    }
}
