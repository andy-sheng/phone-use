import SwiftUI

struct AutomationLibraryPage: View {
    @ObservedObject var automation: AutomationModel
    let open: (AutomationTask) -> Void
    let importTask: () -> Void
    @State private var search = ""

    private var matches: [AutomationTask] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return automation.tasks }
        return automation.tasks.filter {
            ($0.title + $0.metadata.subtitle + $0.metadata.author + $0.metadata.source)
                .localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("共 \(automation.tasks.count) 项任务").font(.callout).foregroundStyle(.secondary)
                Spacer()
            }
            TextField("搜索任务", text: $search).textFieldStyle(.roundedBorder)
            if automation.isRunning {
                Text("当前任务正在运行，停止后可切换到其他任务。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if matches.isEmpty {
                ContentUnavailableView {
                    Label(automation.tasks.isEmpty ? "暂无已保存任务" : "没有匹配的任务", systemImage: "tray")
                } description: {
                    Text(automation.tasks.isEmpty ? "导入的任务会保存在这里。" : "换个名称、作者或任务编号搜索。")
                } actions: {
                    if automation.tasks.isEmpty && automation.canImport { Button("导入任务", action: importTask) }
                }
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(matches) { item in
                            HStack(spacing: 12) {
                                Image(systemName: "doc.text").font(.title3).foregroundStyle(.secondary)
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(item.title).font(.callout.weight(.semibold)).lineLimit(2)
                                    Text(automation.pluginName(item.pluginID) + (item.isBuiltIn ? " · 内置任务" : "")).font(.caption2).foregroundStyle(.secondary)
                                    Text(item.metadata.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
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
                                Button { automation.removeTask(item) } label: { Image(systemName: "trash") }
                                    .buttonStyle(.borderless).foregroundStyle(.secondary)
                                    .disabled(automation.isBusy || item.isBuiltIn)
                                    .accessibilityLabel("删除任务：\(item.title)")
                                    .help("删除列表中的副本，移至废纸篓")
                            }
                            .padding(14)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
                        }
                    }
                }
            }
            if let error = automation.libraryError {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
