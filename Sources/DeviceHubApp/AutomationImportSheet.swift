import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct AutomationImportSheet: View {
    @ObservedObject var automation: AutomationModel
    @Environment(\.dismiss) private var dismiss
    @State private var selectedImportID: String?
    @State private var source = ""
    @State private var file: URL?
    @FocusState private var sourceFocused: Bool

    private var sources: [AutomationPlugin.ImportSource] { automation.selectedPlugin?.imports ?? [] }
    private var provider: AutomationPlugin.ImportSource? { sources.first { $0.id == selectedImportID } ?? sources.first }
    private var canImport: Bool {
        automation.canImport && (provider?.kind == "source" ? !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty : file != nil)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Text("导入任务").font(.title2.weight(.semibold))
                Text("\(automation.selectedPlugin?.name ?? "插件") · 导入后保存到任务库，不会自动运行。")
                    .font(.callout).foregroundStyle(.secondary)
            }
            if sources.count > 1 {
                Picker("导入方式", selection: $selectedImportID) {
                    ForEach(sources) { item in Text(item.title).tag(Optional(item.id)) }
                }
                .pickerStyle(.segmented)
                .disabled(automation.isImporting)
            }
            if let provider {
                Group {
                    if provider.kind == "source" {
                        TextField(provider.placeholder ?? "输入任务来源", text: $source)
                            .textFieldStyle(.roundedBorder).focused($sourceFocused)
                            .onSubmit { importTask() }
                    } else {
                        HStack(spacing: 12) {
                            Image(systemName: "doc.text").font(.title2).foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(file?.lastPathComponent ?? "选择任务文件").lineLimit(2)
                                Text(provider.title).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button(file == nil ? "选择文件…" : "更换…", action: chooseFile)
                        }
                        .padding(14)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
                    }
                    if let url = provider.helpURL, ["https", "http"].contains(url.scheme?.lowercased() ?? "") {
                        Link(provider.helpTitle ?? "查看导入说明", destination: url).font(.caption)
                    }
                }
                .disabled(automation.isImporting)
            }
            if let message = automation.importMessage {
                Text(message).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
            }
            HStack {
                if automation.isImporting { ProgressView().controlSize(.small) }
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction).disabled(automation.isImporting)
                Button(automation.isImporting ? "正在导入…" : "导入", action: importTask)
                    .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent).disabled(!canImport)
            }
        }
        .padding(24)
        .frame(width: 480)
        .interactiveDismissDisabled(automation.isImporting)
        .onAppear {
            automation.prepareImport()
            selectedImportID = sources.first?.id
            sourceFocused = true
        }
        .onChange(of: automation.importGeneration) { _, _ in dismiss() }
        .onChange(of: selectedImportID) { _, _ in file = nil; source = "" }
    }

    private func importTask() {
        guard canImport else { return }
        if provider?.kind == "source" { automation.importTask(source: source) }
        else if let file { automation.importTask(file: file) }
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        let types = (provider?.extensions ?? []).compactMap { UTType(filenameExtension: $0) }
        if !types.isEmpty { panel.allowedContentTypes = types }
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if let window = NSApp.keyWindow {
            panel.beginSheetModal(for: window) { response in
                if response == .OK { file = panel.url }
            }
        } else {
            panel.begin { response in if response == .OK { file = panel.url } }
        }
    }
}
