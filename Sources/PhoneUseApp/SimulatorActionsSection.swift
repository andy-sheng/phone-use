import PhoneUseKit
import SwiftUI

struct SimulatorActionsSection: View {
    let device: DeviceSummary

    @State private var url = ""
    @State private var bundleID = ""
    @State private var payload = """
    {
      "aps": {
        "alert": "测试通知"
      }
    }
    """
    @State private var operation: Task<Void, Never>?
    @State private var feedback: String?
    @State private var failed = false

    var body: some View {
        Section("模拟器工具") {
            LabeledContent("截图状态栏") {
                HStack {
                    Button("设为 9:41") {
                        run(.screenshotStatusBar, success: "已应用 9:41 截图状态栏")
                    }
                    Button("恢复默认") {
                        run(.clearStatusBar, success: "已清除状态栏覆盖")
                    }
                    .help("清除这台模拟器的所有状态栏覆盖")
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Label("打开深链", systemImage: "link")
                HStack {
                    TextField("链接", text: $url, prompt: Text(verbatim: "myapp://path"))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(openLink)
                    Button("打开", action: openLink)
                        .disabled(trimmedURL.isEmpty)
                }
            }

            DisclosureGroup("模拟推送通知") {
                VStack(alignment: .leading, spacing: 8) {
                    TextField("Bundle ID", text: $bundleID, prompt: Text(verbatim: "com.example.app"))
                        .textFieldStyle(.roundedBorder)
                    Text("APNs JSON").font(.caption)
                    TextEditor(text: $payload)
                        .font(.system(.body, design: .monospaced))
                        .autocorrectionDisabled()
                        .accessibilityLabel("APNs JSON")
                        .frame(height: 96)
                        .border(.secondary.opacity(0.25))
                    Button("发送通知") {
                        run(.push(bundleID: bundleID.trimmingCharacters(in: .whitespacesAndNewlines),
                                  payload: payload), success: "已向模拟器提交推送")
                    }
                    .disabled(bundleID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                              payload.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .padding(.vertical, 4)
            }

            if operation != nil {
                ProgressView().controlSize(.small)
            } else if let feedback {
                Label(feedback, systemImage: failed ? "exclamationmark.triangle" : "checkmark.circle")
                    .font(.callout)
                    .foregroundStyle(failed ? Color.orange : .secondary)
                    .textSelection(.enabled)
            }
        }
        .disabled(operation != nil)
        .onDisappear { operation?.cancel() }
    }

    private var trimmedURL: String { url.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func openLink() {
        guard !trimmedURL.isEmpty else { return }
        run(.openURL(trimmedURL), success: "链接已提交。如果模拟器询问是否打开，请在模拟器中确认。")
    }

    private func run(_ action: SimulatorDeveloperAction, success: String) {
        guard operation == nil else { return }
        feedback = nil
        operation = Task { @MainActor in
            defer { operation = nil }
            do {
                try await action.run(on: device)
                guard !Task.isCancelled else { return }
                failed = false
                feedback = success
            } catch {
                guard !Task.isCancelled else { return }
                failed = true
                feedback = String(describing: error)
            }
        }
    }
}
