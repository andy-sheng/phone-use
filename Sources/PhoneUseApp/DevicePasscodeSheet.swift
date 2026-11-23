import PhoneUseKit
import SwiftUI

struct DevicePasscodeSheet: View {
    let device: DeviceSummary
    let status: UnlockCredential.Status?
    let didSave: () -> Void

    @Environment(\.dismiss) private var dismiss
    @FocusState private var isFocused: Bool
    @State private var usesPIN: Bool
    @State private var pin = ""
    @State private var saving = false
    @State private var error: String?

    private var hasPasscode: Bool { status?.hasPIN == true }

    init(device: DeviceSummary, status: UnlockCredential.Status?, didSave: @escaping () -> Void) {
        self.device = device
        self.status = status
        self.didSave = didSave
        _usesPIN = State(initialValue: status?.hasPIN == true || (status != .noPasscode && !device.isSimulator))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(hasPasscode ? "更改解锁密码" : "设置解锁密码").font(.headline)
                Text(device.name).foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 6) {
                Picker("设备锁屏密码", selection: $usesPIN) {
                    Text("无密码").tag(false)
                    Text("数字密码").tag(true)
                }
                .pickerStyle(.segmented)
                if usesPIN {
                    SecureField("解锁密码", text: $pin, prompt: Text(verbatim: hasPasscode ? "******" : "4 位或 6 位数字密码"))
                        .textFieldStyle(.roundedBorder)
                        .focused($isFocused)
                        .onSubmit(save)
                    Text(hasPasscode ? "输入新的 4 位或 6 位数字密码，替换本机钥匙串中的密码。" : "密码将保存在本机钥匙串。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("PhoneUse 会尝试直接解锁。此设置仅保存在本机。")
                        .font(.caption).foregroundStyle(.secondary)
                }
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
                    .disabled(usesPIN && !DeviceSession.validUnlockPIN(pin))
            }
        }
        .padding(24)
        .frame(width: 360)
        .disabled(saving)
        .interactiveDismissDisabled(saving)
        .onAppear { isFocused = usesPIN }
        .onChange(of: usesPIN) { _, enabled in
            if !enabled { pin = "" }
            isFocused = enabled
        }
    }

    private func save() {
        guard !saving, !usesPIN || DeviceSession.validUnlockPIN(pin) else { return }
        saving = true
        error = nil
        Task { @MainActor in
            do {
                try await DeviceUnlockController.shared.configure(device, setting: usesPIN ? .pin(pin) : .noPasscode)
                didSave()
                dismiss()
            } catch {
                self.error = String(describing: error)
                saving = false
            }
        }
    }
}
