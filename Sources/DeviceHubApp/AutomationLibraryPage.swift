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
                Text("已保存 \(automation.tasks.count) 份作业").font(.callout).foregroundStyle(.secondary)
                Spacer()
            }
            TextField("搜索作业", text: $search).textFieldStyle(.roundedBorder)
            if automation.isRunning {
                Text("当前作业正在运行，停止后可切换到其他作业。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if matches.isEmpty {
                ContentUnavailableView {
                    Label(automation.tasks.isEmpty ? "暂无已保存作业" : "没有匹配的作业", systemImage: "tray")
                } description: {
                    Text(automation.tasks.isEmpty ? "导入的作业会保存在这里。" : "换个名称、作者或作业编号搜索。")
                } actions: {
                    if automation.tasks.isEmpty { Button("导入作业", action: importTask) }
                }
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(matches) { item in
                            HStack(spacing: 12) {
                                Image(systemName: "doc.text").font(.title3).foregroundStyle(.secondary)
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(item.title).font(.callout.weight(.semibold)).lineLimit(2)
                                    Text(item.metadata.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                    if !item.metadata.author.isEmpty {
                                        Text(item.metadata.author).font(.caption2).foregroundStyle(.secondary)
                                    }
                                    if automation.selectedTaskID == item.id {
                                        Text("当前作业").font(.caption2).foregroundStyle(Color.accentColor)
                                    }
                                }
                                Spacer(minLength: 4)
                                Button("打开") { open(item) }
                                    .disabled(automation.isImporting || automation.isRefreshingTasks || (automation.isRunning && automation.selectedTaskID != item.id))
                                    .accessibilityLabel("打开作业：\(item.title)")
                                Button { automation.removeTask(item) } label: { Image(systemName: "trash") }
                                    .buttonStyle(.borderless).foregroundStyle(.secondary)
                                    .disabled(automation.isRunning || automation.isImporting || automation.isRefreshingTasks)
                                    .accessibilityLabel("删除作业：\(item.title)")
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
