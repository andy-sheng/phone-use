import PhoneUseKit
import SwiftUI

enum DeviceManagementAction: String, Identifiable {
    case shutDown, restart, showInFinder, rename, erase, remove, unpair, collectSysdiagnose, carPlay

    var id: Self { self }

    var title: String {
        switch self {
        case .shutDown: "关机"
        case .restart: "重启"
        case .showInFinder: "在 Finder 中显示"
        case .rename: "重命名"
        case .erase: "抹掉所有内容和设置"
        case .remove: "删除模拟器"
        case .unpair: "取消 Xcode 配对"
        case .collectSysdiagnose: "收集 sysdiagnose"
        case .carPlay: "CarPlay 模拟器"
        }
    }

    var interruptsPreview: Bool {
        switch self {
        case .shutDown, .restart, .erase, .remove, .unpair: true
        default: false
        }
    }
}

struct DeviceManagementRequest: Identifiable {
    let action: DeviceManagementAction
    let device: DeviceSummary
    var id: DeviceManagementAction { action }
}

struct DeviceManagementPrompt: View {
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    let request: DeviceManagementRequest
    let submit: (String) -> Void

    init(_ request: DeviceManagementRequest, submit: @escaping (String) -> Void) {
        self.request = request
        self.submit = submit
        _name = State(initialValue: request.device.name)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(request.action.title).font(.headline)
            if request.action == .rename {
                TextField("设备名称", text: $name)
            } else {
                Text(message).foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(request.action.title, role: destructive ? .destructive : nil) {
                    dismiss()
                    submit(name)
                }
                .keyboardShortcut(destructive ? nil : .defaultAction)
                .disabled(request.action == .rename && (name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || name.trimmingCharacters(in: .whitespacesAndNewlines) == request.device.name))
            }
        }
        .frame(width: 340)
        .padding(22)
    }

    private var destructive: Bool { [.erase, .remove, .unpair].contains(request.action) }

    private var message: String {
        let device = request.device.name
        return switch request.action {
        case .erase: "将清除 \(device) 中的所有应用、数据和设置。"
        case .remove: "将从这台 Mac 删除模拟器 \(device) 及其数据。"
        case .unpair: "将解除 \(device) 与这台 Mac 在 Xcode 中的配对。"
        case .restart: "\(device) 将立即重启，正在共享的屏幕会断开。"
        default: device
        }
    }
}
