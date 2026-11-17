import Foundation

/// Hinge presets supported by dual-screen iOS simulators such as iPhone Duo.
public enum SimulatorPosture: String, CaseIterable, Sendable {
    case closed, partiallyOpen, openFlat

    public var angle: Double {
        switch self {
        case .closed: 0
        case .partiallyOpen: 90
        case .openFlat: 180
        }
    }

    var command: [String: Any] {
        ["provider": "com.apple.Virtualization.VirtualMachines",
         "source": "hinge-slider-control", "type": "range", "value": angle]
    }
}
