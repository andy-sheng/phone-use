import Foundation

extension DeviceSummary {
    public var appPackageExtension: String {
        if isAndroid { return "apk" }
        return isSimulator ? "app" : "ipa"
    }

    public var appPackageDescription: String {
        if isAndroid { return "Android APK (.apk)" }
        return isSimulator ? "iOS Simulator build (.app)" : "Signed iOS device build (.ipa)"
    }
}

extension DeviceHub {
    public func installApp(from source: URL, on device: DeviceSummary,
                           onInstalling: @Sendable () async -> Void = {}) async throws {
        guard device.isReady else {
            throw DeviceHubError.deviceNotReady("\(device.name) is not ready (\(device.state.rawValue))")
        }
        if source.isFileURL {
            await onInstalling()
            try Task.checkCancellation()
            try await installLocalApp(source, on: device)
        } else {
            try await AppPackageDownload.withPackage(from: source, for: device) { file in
                await onInstalling()
                try Task.checkCancellation()
                try await self.installLocalApp(file, on: device)
            }
        }
    }

    private func installLocalApp(_ file: URL, on device: DeviceSummary) async throws {
        guard file.pathExtension.lowercased() == device.appPackageExtension else {
            throw DeviceHubError.serviceFailed("Choose a \(device.appPackageDescription) for \(device.name).")
        }
        if device.isSimulator {
            let values = try file.resourceValues(forKeys: [.isDirectoryKey])
            guard values.isDirectory == true else {
                throw DeviceHubError.serviceFailed("Choose an iOS Simulator .app bundle.")
            }
            if let platforms = Bundle(url: file)?.object(forInfoDictionaryKey: "CFBundleSupportedPlatforms") as? [String],
               !platforms.contains("iPhoneSimulator") {
                throw DeviceHubError.serviceFailed("This .app targets \(platforms.joined(separator: ", ")). Choose a build for iOS Simulator.")
            }
            try await SimulatorLifecycle.install(file, on: device)
        } else {
            try await daemon().installApp(device.udid, from: file)
        }
    }
}
