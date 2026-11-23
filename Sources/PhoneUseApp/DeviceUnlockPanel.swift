import PhoneUseKit
import SwiftUI

struct DeviceUnlockPanel: View {
    let device: DeviceSummary
    let credentialStatus: UnlockCredential.Status?
    let editPasscode: () -> Void
    let refreshCredentials: () -> Void
    @State private var message = ""
    @State private var busy = false

    private var canEdit: Bool { !device.isAndroid || device.isReady }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("设备解锁", systemImage: "lock.open")
                Spacer()
                Button("一键解锁") {
                    run {
                        let result = try await DeviceUnlockController.shared.unlock(device)
                        switch result {
                        case .unlocked: return "已解锁"
                        case .alreadyUnlocked: return "设备已解锁"
                        case .noPasscodeRequired: return "设备当前无需密码，未确认锁屏界面状态。"
                        case .needsUserUnlock: return "请在设备上解锁，当前无法确认系统密码键盘。"
                        case .needsPasscode: return "请先保存这台设备的数字密码。"
                        case .unconfirmed: return "未确认解锁。请在设备上核对，然后重新保存密码。"
                        }
                    }
                }.disabled(!device.isReady)
            }
            HStack(alignment: .firstTextBaseline) {
                Text(credentialStatus == .pending ? "上次输入未确认" : credentialStatus?.rawValue ?? "密码状态未知")
                    .foregroundStyle(credentialStatus == .pending ? .orange : .secondary)
                    .help(credentialStatus?.rawValue ?? "密码状态未知")
                Spacer()
                Button(credentialStatus?.hasPIN == true ? "更改密码…" : "设置密码…") {
                    message = ""
                    editPasscode()
                }
                if credentialStatus?.hasPIN == true {
                    Button("移除", role: .destructive) {
                        run {
                            try await DeviceUnlockController.shared.configure(device, pin: nil)
                            return ""
                        }
                    }
                }
            }
            .disabled(!canEdit)
            if !message.isEmpty {
                Text(message).font(.caption)
            }
        }
        .padding()
        .disabled(busy)
        .onAppear(perform: refreshCredentials)
    }

    private func run(_ action: @escaping () async throws -> String) {
        busy = true
        message = ""
        Task {
            defer { busy = false }
            do { message = try await action() }
            catch { message = String(describing: error) }
            refreshCredentials()
        }
    }
}
