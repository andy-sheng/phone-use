// swift-tools-version: 6.0
import Foundation
import PackageDescription

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path

func infoPlist(_ name: String) -> [LinkerSetting] {
    [.unsafeFlags([
        "-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__info_plist",
        "-Xlinker", "\(root)/Support/\(name)",
    ])]
}

// SwiftPM records the deployment target as the SDK version, and AppKit keeps apps linked against
// an SDK older than 26 in the pre-Liquid Glass appearance (no floating sidebar, no glass).
let modernAppearance: [LinkerSetting] = [
    .unsafeFlags(["-Xlinker", "-platform_version", "-Xlinker", "macos", "-Xlinker", "15.0", "-Xlinker", "26.0"]),
]

// Targets keep three layers apart so they can later move into separate repositories:
// - PhoneUseKit / PhoneUseUI: the device framework (sessions, platforms, streams, daemon client,
//   shared device views). It knows no app, no MCP and no MaaFramework.
// - phone-use: PhoneUseApp, PhoneUseCLI, PhoneUseMCP and PhoneUseMCPServer.
// - automation: AutomationApp and AutomationBridge, plus the Python runtime in Automation/.
// The two apps never depend on each other.
let package = Package(
    name: "phone-use",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "PhoneUseKit", targets: ["PhoneUseKit"]),
        .library(name: "PhoneUseUI", targets: ["PhoneUseUI"]),
        .library(name: "PhoneUseMCP", targets: ["PhoneUseMCP"]),
        .executable(name: "phone-use", targets: ["PhoneUseCLI"]),
        .executable(name: "phone-use-mcp", targets: ["PhoneUseMCPServer"]),
        .executable(name: "phone-use-app", targets: ["PhoneUseApp"]),
        .executable(name: "automation-app", targets: ["AutomationApp"]),
        .executable(name: "automation-bridge", targets: ["AutomationBridge"]),
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.1"),
    ],
    targets: [
        // Framework
        .target(name: "PhoneUseKit"),
        .target(name: "PhoneUseUI", dependencies: ["PhoneUseKit"], resources: [.process("Resources")]),

        // phone-use
        .target(name: "PhoneUseMCP", dependencies: ["PhoneUseKit"]),
        .executableTarget(name: "PhoneUseCLI", dependencies: ["PhoneUseKit"]),
        .executableTarget(name: "PhoneUseMCPServer", dependencies: ["PhoneUseKit", "PhoneUseMCP"]),
        .executableTarget(
            name: "PhoneUseApp",
            dependencies: ["PhoneUseKit", "PhoneUseUI", "PhoneUseMCP", .product(name: "Sparkle", package: "Sparkle")],
            resources: [.process("Resources")],
            // A bare SwiftPM executable has no bundle, so the camera usage string USB capture
            // needs is embedded straight into the binary. Packaged builds get a real Info.plist.
            linkerSettings: infoPlist("PhoneUseApp-Info.plist") + modernAppearance
        ),

        // automation
        .executableTarget(
            name: "AutomationApp",
            dependencies: ["PhoneUseKit", "PhoneUseUI"],
            linkerSettings: infoPlist("AutomationApp-Info.plist") + modernAppearance
        ),
        .executableTarget(name: "AutomationBridge", dependencies: ["PhoneUseKit"]),

        .testTarget(name: "PhoneUseKitTests", dependencies: ["PhoneUseKit"]),
        .testTarget(name: "PhoneUseUITests", dependencies: ["PhoneUseUI", "PhoneUseKit"]),
        .testTarget(name: "PhoneUseMCPTests", dependencies: ["PhoneUseMCP", "PhoneUseKit"]),
        .testTarget(name: "PhoneUseAppTests", dependencies: ["PhoneUseApp", "PhoneUseKit"]),
    ],
    swiftLanguageModes: [.v5]
)
