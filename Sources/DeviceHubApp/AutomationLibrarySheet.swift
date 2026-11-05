import SwiftUI

struct AutomationLibrarySheet: View {
    @EnvironmentObject private var automation: AutomationModel
    @Environment(\.dismiss) private var dismiss
    @State private var showsImport = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("任务列表").font(.title2.weight(.semibold))
                    Text("打开任务后，切换主界面中的当前任务。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button { showsImport = true } label: { Label("导入任务", systemImage: "plus") }
                    .buttonStyle(.borderedProminent)
                    .disabled(!automation.canImport)
            }
            .padding(20)
            Divider()
            AutomationLibraryPage(automation: automation, open: { task in
                if automation.openTask(task) { dismiss() }
            }, importTask: { showsImport = true })
            Divider()
            HStack {
                Spacer()
                Button("关闭") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(16)
        }
        .frame(width: 720, height: 560)
        .sheet(isPresented: $showsImport) { AutomationImportSheet(automation: automation) }
        .interactiveDismissDisabled(automation.isImporting)
        .onChange(of: automation.importGeneration) { _, _ in dismiss() }
    }
}
