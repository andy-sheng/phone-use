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
