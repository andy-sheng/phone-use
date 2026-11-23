import PhoneUseKit
import PhoneUseUI
import SwiftUI

struct DeviceUnlockPanel: View {
    let device: DeviceSummary
    let credentialStatus: UnlockCredential.Status?
    let editPasscode: () -> Void
    let refreshCredentials: () -> Void
    @State private var message = ""
    @State private var busy = false

    private var canEdit: Bool { !device.isAndroid || device.isReady }

    private var statusLabel: String {
        if credentialStatus == .pending { return "上次输入未确认" }
        if device.isSimulator && credentialStatus == .missing { return "默认按无密码解锁" }
        return credentialStatus?.rawValue ?? "密码状态未知"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("设备解锁", systemImage: "lock.open")
                Spacer()
                Button("一键解锁") {
                    run {
                        let result = try await DeviceUnlockController.shared.unlock(device)
                        return result.displayMessage
                    }
                }.disabled(!device.isReady)
            }
            HStack(alignment: .firstTextBaseline) {
                Text(statusLabel)
                    .foregroundStyle(credentialStatus == .pending ? .orange : .secondary)
                    .help(statusLabel)
                Spacer()
                Button(credentialStatus?.hasPIN == true ? "更改密码…" : "设置密码…") {
                    message = ""
                    editPasscode()
                }
                if let credentialStatus, credentialStatus != .missing {
                    Button("移除", role: .destructive) {
                        run {
                            try await DeviceUnlockController.shared.configure(device, setting: .remove)
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
