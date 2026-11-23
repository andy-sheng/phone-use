import Foundation

extension DeviceOrientation {
    /// DeviceHub's Pop plugin updates the VM motion sensor, rather than only BackBoard's override.
    var command: [String: Any] {
        let value: String = switch self {
        case .portrait: "portrait"
        case .portraitUpsideDown: "pud"
        case .landscapeLeft: "landscape-left"
        case .landscapeRight: "landscape-right"
        }
        return ["provider": "com.apple.Virtualization.VirtualMachines",
                "source": "orientation-picker-control", "type": "enum", "value": value]
    }
}
