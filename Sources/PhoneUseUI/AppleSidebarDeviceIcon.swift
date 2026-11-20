import PhoneUseKit
import SwiftUI

/// The sidebar reflects discovery state even when the screen preview is closed.
struct AppleSidebarDeviceIcon: View {
    let device: DeviceSummary

    private var isLit: Bool {
        guard device.isSimulator, let state = device.simulatorState else { return device.isReady }
        return state == "Booted"
    }

    private var isDuo: Bool { device.productType?.localizedCaseInsensitiveContains("Duo") == true }
    private var deviceWidth: CGFloat { device.isPad ? 16 : isDuo ? 14 : 11 }
    private var cornerRadius: CGFloat { device.isPad ? 2 : isDuo ? 2.4 : 2.8 }
    private var outline: Color { isLit ? .black : .secondary.opacity(0.45) }

    private var statusDescription: String {
        if !device.isSimulator {
            if device.isReady { return "已连接" }
            return device.isAttached ? "尚未就绪" : "未连接"
        }
        return switch device.simulatorState {
        case "Booted": "已开机"
        case "Booting": "正在开机"
        case "Shutting Down": "正在关机"
        case "Shutdown": "已关机"
        default: device.isReady ? "已开机" : "不可用"
        }
    }

    var body: some View {
        ZStack {
            Circle().fill(.primary.opacity(isLit ? 0.20 : 0.06))
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(isLit ? Color(red: 0.30, green: 0.77, blue: 0.95) : .clear)
                .overlay {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(outline, lineWidth: isLit ? 0.9 : 0.7)
                }
                .overlay(alignment: isDuo ? .topTrailing : .top) {
                    if !device.isPad {
                        Capsule()
                            .fill(outline)
                            .frame(width: isDuo ? 1.5 : 3.2, height: 1.2)
                            .padding(.top, 1.8)
                            .padding(.trailing, isDuo ? 2 : 0)
                    }
                }
                .overlay(alignment: .bottom) {
                    Capsule().fill(outline)
                        .frame(width: deviceWidth * 0.33, height: 0.7)
                        .padding(.bottom, 1.6)
                }
                .frame(width: deviceWidth, height: 20)
        }
        .frame(width: 32, height: 32)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(device.isSimulator ? "模拟器" : device.platformName)，\(statusDescription)")
        .help(statusDescription)
    }
}
