import AppKit
import PhoneUseKit
import SwiftUI
import UniformTypeIdentifiers

/// Both applications share the export UI; each app supplies its own optional run log folders.
public struct DiagnosticCommands: Commands {
    private let runDirectories: () -> [URL]
    @State private var exporting = false

    public init(runDirectories: @escaping () -> [URL] = { [] }) {
        self.runDirectories = runDirectories
    }

    public var body: some Commands {
        CommandGroup(after: .help) {
            Button(exporting ? "正在导出诊断日志…" : "导出诊断日志…", action: export)
                .disabled(exporting)
            Button("打开诊断日志文件夹") {
                let directory = PhoneUseConfiguration.current.logDirectory
                do {
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    NSWorkspace.shared.open(directory)
                } catch { NSAlert(error: error).runModal() }
            }
        }
    }

    @MainActor private func export() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.zip]
        panel.nameFieldStringValue = "\(PhoneUseConfiguration.current.displayName)-diagnostics-\(Int(Date().timeIntervalSince1970)).zip"
        panel.message = "包含设备连接和近期运行的文本日志，可能含设备名称、网络地址及插件消息；不包含截图、配对凭据或任务文件。"
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        exporting = true
        let configuration = PhoneUseConfiguration.current
        let runs = runDirectories()
        let metadata = Diagnostics.metadata
        Diagnostics.record("diagnostics.export")
        Task {
            do {
                try await Task.detached {
                    try DiagnosticBundle.archive(to: destination, configuration: configuration,
                                                 runDirectories: runs, metadata: metadata)
                }.value
                NSWorkspace.shared.activateFileViewerSelecting([destination])
            } catch { NSAlert(error: error).runModal() }
            exporting = false
        }
    }
}
