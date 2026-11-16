import XCTest
@testable import PhoneUseApp

@MainActor
final class AppUpdaterTests: XCTestCase {
    func testAnActiveTaskDefersRelaunchUntilItFinishesExactlyOnce() {
        let updater = AppUpdater()
        var installs = 0
        updater.setTaskRunning(true)
        XCTAssertTrue(updater.deferInstallationIfTaskRunning { installs += 1 })
        updater.setTaskRunning(true)
        XCTAssertEqual(installs, 0)
        updater.setTaskRunning(false)
        XCTAssertEqual(installs, 1)
        updater.setTaskRunning(false)
        XCTAssertEqual(installs, 1)
    }

    func testAnIdleAppDoesNotPostponeInstallation() {
        let updater = AppUpdater()
        XCTAssertFalse(updater.deferInstallationIfTaskRunning { XCTFail("Sparkle owns the immediate install") })
    }
}
