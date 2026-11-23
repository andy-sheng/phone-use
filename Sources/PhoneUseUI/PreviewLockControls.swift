import PhoneUseKit
import SwiftUI

enum PreviewLockAction: Equatable {
    case lock, unlock, check

    init(_ state: DeviceLockStatus.State) {
        switch state {
        case .locked: self = .unlock
        case .unlocked: self = .lock
        case .unknown: self = .check
        }
    }

    var title: String {
        switch self {
        case .lock: "锁定屏幕"
        case .unlock: "解锁屏幕"
        case .check: "检查锁屏状态"
        }
    }

    var icon: String {
        switch self {
        case .lock: "lock"
        case .unlock: "lock.open"
        case .check: "lock.rotation"
        }
    }

    /// A stale click must never send the opposite action. Some iOS versions need a manual choice.
    func perform(current: DeviceLockStatus.State, manual: Bool,
                 lock: () async throws -> Void, unlock: () async throws -> DeviceUnlockResult) async throws -> PreviewLockNotice? {
        let available = PreviewLockAction(current)
        if available == .check && !manual { return .unknown }
        guard available == self || (manual && available == .check) else { return nil }
        switch self {
        case .check: return nil
        case .lock:
            try await lock()
            try await Task.sleep(for: .milliseconds(350))
            return nil
        case .unlock:
            switch try await unlock() {
            case .alreadyUnlocked, .unlocked: return nil
            case .needsPasscode: return .missingPasscode
            case let result: return .message(result.displayMessage)
            }
        }
    }
}

public extension DeviceUnlockResult {
    var displayMessage: String {
        switch self {
        case .unlocked: "已解锁"
        case .alreadyUnlocked: "设备已解锁"
        case .noPasscodeRequired: "设备当前无需密码，未确认锁屏界面状态。"
        case .needsUserUnlock: "请在设备上解锁，当前无法确认系统密码键盘。"
        case .needsPasscode: "请先保存这台设备的数字密码。"
        case .unconfirmed: "未确认解锁。请在设备上核对，然后重新保存密码。"
        }
    }
}

enum PreviewLockNotice: Equatable {
    case missingPasscode, unknown, message(String)
}

struct PreviewLockControls<Content: View>: View {
    let device: DeviceSummary
    let lock: () async throws -> Void
    let unlock: () async throws -> DeviceUnlockResult
    let configure: (() -> Void)?
    let content: (String, String, Bool, @escaping () -> Void) -> Content

    private struct Request: Equatable {
        let action: PreviewLockAction
        var manual = false
    }

    @State private var action = PreviewLockAction.check
    @State private var request: Request?
    @State private var notice: PreviewLockNotice?

    var body: some View {
        content(action.title, action.icon, request != nil) {
            guard request == nil else { return }
            request = Request(action: action)
        }
        .task(id: request) { await update(request) }
        .alert(alertTitle, isPresented: Binding(get: { notice != nil }, set: { if !$0 { notice = nil } }),
               presenting: notice) { notice in
            switch notice {
            case .missingPasscode:
                if let configure { Button("设置密码…", action: configure) }
                Button("取消", role: .cancel) {}
            case .unknown:
                Button("锁定屏幕") { request = Request(action: .lock, manual: true) }
                Button("解锁屏幕") { request = Request(action: .unlock, manual: true) }
                Button("取消", role: .cancel) {}
            case .message:
                Button("好") {}
            }
        } message: { notice in
            switch notice {
            case .missingPasscode: Text("请在「设置密码」里选择「无密码」，或填写「\(device.name)」已有的数字密码。")
            case .unknown: Text("「\(device.name)」未报告锁屏状态。请根据设备屏幕选择操作。")
            case .message(let message): Text(message)
            }
        }
    }

    private var alertTitle: String {
        switch notice {
        case .missingPasscode: "检查设备解锁设置"
        case .unknown: "无法确认锁屏状态"
        default: "设备锁屏操作"
        }
    }

    @MainActor
    private func update(_ pending: Request?) async {
        if let pending {
            do {
                let state = await DeviceHub.shared.lockStatus(for: device).state
                try Task.checkCancellation()
                action = PreviewLockAction(state)
                let result = try await pending.action.perform(current: state, manual: pending.manual, lock: lock, unlock: unlock)
                try Task.checkCancellation()
                notice = result
            } catch {
                guard !Task.isCancelled else { return }
                notice = .message(String(describing: error))
            }
            request = nil
        } else {
            while !Task.isCancelled {
                let state = await DeviceHub.shared.lockStatus(for: device).state
                guard !Task.isCancelled else { return }
                action = PreviewLockAction(state)
                do { try await Task.sleep(for: .seconds(3)) } catch { return }
            }
        }
    }
}
