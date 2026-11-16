import Foundation
import PhoneUseKit

// automation's private device connection for the Maa runtime: JSON lines on stdin/stdout, one
// device session per process. The parent passes its daemon identity through the environment
// (`PhoneUseConfiguration.environment`); run by hand it uses automation's own daemon.
//
//   automation-bridge [--device <name|udid|android:serial|simulator:udid>]

if PhoneUseConfiguration.inherited() == nil {
    // Must match AutomationApp's identity.
    PhoneUseConfiguration.current = .application(identifier: "dev.devicehub.automation", displayName: "automation")
}

var arguments = Array(CommandLine.arguments.dropFirst())
var deviceQuery: String?
if let index = arguments.firstIndex(of: "--device"), index + 1 < arguments.count {
    deviceQuery = arguments[index + 1]
    arguments.removeSubrange(index...index + 1)
}
guard arguments.isEmpty else {
    FileHandle.standardError.write(Data("usage: automation-bridge [--device <query>]\n".utf8))
    exit(64)
}

await runAutomationBridge(deviceQuery: deviceQuery)
