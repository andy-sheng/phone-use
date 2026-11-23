import PhoneUseKit
import SwiftUI

struct AppInstallationRequest: Identifiable {
    let id = UUID()
    let device: DeviceSummary
    let file: URL?
}

struct AppInstallationSheet: View {
    let request: AppInstallationRequest
    @Environment(\.dismiss) private var dismiss
    @State private var link = ""
    @State private var download: URL?
    @State private var installing = false
    @State private var result: String?

    private var source: URL? { request.file ?? download }
    private var enteredURL: URL? {
        try? AppPackageDownload.url(link.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("安装到 \(request.device.name)").font(.headline)
            if let source {
                Text(source.lastPathComponent.isEmpty ? (source.host ?? "") : source.lastPathComponent).lineLimit(2)
                if let result {
                    Text(result).textSelection(.enabled)
                } else {
                    ProgressView(installing || source.isFileURL ? "正在安装…" : "正在下载安装包…").controlSize(.small)
                }
            } else {
                Text(request.device.isSimulator ? "下载包含一个模拟器版 .app 的 ZIP 文件。" : "输入 .\(request.device.appPackageExtension) 安装包的直接下载链接。")
                TextField("http:// 或 https://", text: $link)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { download = enteredURL }
            }
            HStack {
                Spacer()
                if result != nil {
                    Button("完成") { dismiss() }.keyboardShortcut(.defaultAction)
                } else if !installing && request.file == nil {
                    Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                    if download == nil {
                        Button("下载并安装") { download = enteredURL }
                            .keyboardShortcut(.defaultAction).disabled(enteredURL == nil)
                    }
                }
            }
        }
        .padding(20)
        .frame(width: 420)
        .interactiveDismissDisabled((installing || request.file != nil) && result == nil)
        .task(id: source) {
            guard let source else { return }
            do {
                try await DeviceHub.shared.installApp(from: source, on: request.device) {
                    await MainActor.run { installing = true }
                }
                result = "安装成功"
            } catch {
                if !Task.isCancelled { result = "安装失败：\(error)" }
            }
        }
    }
}
