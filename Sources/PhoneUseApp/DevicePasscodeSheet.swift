import PhoneUseKit
import SwiftUI

struct DevicePasscodeSheet: View {
    let device: DeviceSummary
    let hasPasscode: Bool
    let didSave: () -> Void

    @Environment(\.dismiss) private var dismiss
    @FocusState private var isFocused: Bool
    @State private var pin = ""
    @State private var saving = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(hasPasscode ? "更改解锁密码" : "设置解锁密码").font(.headline)
                Text(device.name).foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 6) {
                SecureField("解锁密码", text: $pin, prompt: Text(verbatim: hasPasscode ? "******" : "4 位或 6 位数字密码"))
                    .textFieldStyle(.roundedBorder)
                    .focused($isFocused)
                    .onSubmit(save)
                Text(hasPasscode ? "输入新的 4 位或 6 位数字密码，替换本机钥匙串中的密码。" : "密码将保存在本机钥匙串。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let error {
                    Text(error).font(.callout).foregroundStyle(.red)
                }
            }

            HStack {
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("保存", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!DeviceSession.validUnlockPIN(pin))
            }
        }
        .padding(24)
        .frame(width: 360)
        .disabled(saving)
        .interactiveDismissDisabled(saving)
        .onAppear { isFocused = true }
    }

    private func save() {
        guard !saving, DeviceSession.validUnlockPIN(pin) else { return }
        saving = true
        error = nil
        Task { @MainActor in
            do {
                try await DeviceUnlockController.shared.configure(device, pin: pin)
                didSave()
                dismiss()
            } catch {
                self.error = String(describing: error)
                saving = false
            }
        }
    }
}
