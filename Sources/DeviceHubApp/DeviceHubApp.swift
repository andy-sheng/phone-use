import AppKit
import DeviceHubKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    var model: AppModel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Launched as a bare SwiftPM executable, so opt into a Dock icon and focus explicitly.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        USBScreenCapture.prepare()
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { model?.stop() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

@main
struct DeviceHubApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup("DeviceHub") {
            ContentView()
                .environmentObject(model)
                .onAppear { appDelegate.model = model }
        }
        .defaultSize(width: 900, height: 920)
    }
}
