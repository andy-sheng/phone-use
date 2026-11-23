import PhoneUseKit
import SwiftUI

struct DeviceUnlockPanel: View {
    let device: DeviceSummary
    let credentialStatus: UnlockCredential.Status?
    let refreshCredentials: () -> Void
    @State private var pin = ""
    @State private var showsPIN = false
    @State private var revealedPIN: String?
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
            HStack {
                Group {
                    if showsPIN {
                        TextField("4 位或 6 位数字密码", text: Binding(
                            get: { revealedPIN ?? pin },
                            set: { revealedPIN = nil; pin = $0 }))
                    } else {
                        SecureField("解锁密码", text: $pin, prompt: Text(verbatim: credentialStatus?.hasPIN == true
                                    ? "******" : "4 位或 6 位数字密码"))
                    }
                }
                .textFieldStyle(.roundedBorder)
                Button {
                    revealedPIN = nil
                    showsPIN.toggle()
                } label: {
                    Image(systemName: showsPIN ? "eye.slash" : "eye")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(showsPIN ? "隐藏密码" : "显示密码")
                .help(showsPIN ? "隐藏密码" : "显示密码")
                Button("保存") {
                    let value = revealedPIN ?? pin
                    clearPIN()
                    run { try await DeviceUnlockController.shared.configure(device, pin: value); return "" }
                }.disabled(!DeviceSession.validUnlockPIN(revealedPIN ?? pin))
                Button("移除") {
                    clearPIN()
                    run { try await DeviceUnlockController.shared.configure(device, pin: nil); return "" }
                }
            }
            .disabled(!canEdit)
            Text("保存在本机钥匙串。保存后，MCP 可解锁这台设备。")
                .font(.caption).foregroundStyle(.secondary)
            Text([credentialStatus?.rawValue ?? "", message].filter { !$0.isEmpty }.joined(separator: " · "))
                .font(.caption)
        }
        .padding()
        .disabled(busy)
        .task(id: showsPIN) {
            guard showsPIN, pin.isEmpty else { return }
            do {
                let saved = try await DeviceUnlockController.shared.savedPIN(device)
                guard !Task.isCancelled, showsPIN, pin.isEmpty else { return }
                revealedPIN = saved
            } catch {
                guard !Task.isCancelled else { return }
                message = String(describing: error)
                showsPIN = false
            }
        }
        .onDisappear { clearPIN() }
        .onAppear(perform: refreshCredentials)
    }

    private func clearPIN() {
        showsPIN = false
        revealedPIN = nil
        pin = ""
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
