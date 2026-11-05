// swift-tools-version: 6.0
import Foundation
import PackageDescription

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path

// A bare SwiftPM executable has no bundle, so the camera usage string USB capture needs is
// embedded straight into the binary. Packaged builds get a real Info.plist instead.
let appInfoPlist: [LinkerSetting] = [
    .unsafeFlags([
        "-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__info_plist",
        "-Xlinker", "\(root)/Support/DeviceHubApp-Info.plist",
    ]),
]

// SwiftPM records the deployment target as the SDK version, and AppKit keeps apps linked against
// an SDK older than 26 in the pre-Liquid Glass appearance (no floating sidebar, no glass).
let modernAppearance: [LinkerSetting] = [
    .unsafeFlags(["-Xlinker", "-platform_version", "-Xlinker", "macos", "-Xlinker", "15.0", "-Xlinker", "26.0"]),
]

let package = Package(
    name: "DeviceHub",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "DeviceHubKit", targets: ["DeviceHubKit"]),
        .executable(name: "devicehub", targets: ["devicehub"]),
        .executable(name: "devicehub-mcp", targets: ["devicehub-mcp"]),
        .executable(name: "DeviceHubApp", targets: ["DeviceHubApp"]),
    ],
    targets: [
        .target(name: "DeviceHubKit"),
        .executableTarget(name: "devicehub", dependencies: ["DeviceHubKit"]),
        .executableTarget(name: "devicehub-mcp", dependencies: ["DeviceHubKit"]),
        .executableTarget(
            name: "DeviceHubApp",
            dependencies: ["DeviceHubKit"],
            resources: [.process("Resources")],
            linkerSettings: appInfoPlist + modernAppearance
        ),
        .testTarget(name: "DeviceHubKitTests", dependencies: ["DeviceHubKit"]),
    ],
    swiftLanguageModes: [.v5]
)
