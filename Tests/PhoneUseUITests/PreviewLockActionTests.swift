import PhoneUseKit
import XCTest
@testable import PhoneUseUI

final class PreviewLockActionTests: XCTestCase {
    func testCurrentStateChoosesOneAction() async throws {
        var presses = 0
        var unlocks = 0
        for state in [DeviceLockStatus.State.unlocked, .locked] {
            let result = try await PreviewLockAction(state).perform(current: state, manual: false) {
                presses += 1
            } unlock: {
                unlocks += 1
                return .unlocked
            }
            XCTAssertNil(result)
            XCTAssertEqual(presses, 1)
            XCTAssertEqual(unlocks, state == .locked ? 1 : 0)
        }
    }

    func testExternalStateChangeDoesNotReverseTheDisplayedAction() async throws {
        for (shown, current) in [(PreviewLockAction.lock, DeviceLockStatus.State.locked), (.unlock, .unlocked)] {
            let result = try await shown.perform(current: current, manual: false) {
                XCTFail("Stale click sent a lock")
            } unlock: {
                XCTFail("Stale click attempted a PIN")
                return .unconfirmed
            }
            XCTAssertNil(result)
        }
    }

    func testUnknownStateOffersChoiceBeforeSendingInput() async throws {
        let prompt = try await PreviewLockAction.unlock.perform(current: .unknown, manual: false) {
            XCTFail()
        } unlock: {
            XCTFail()
            return .unconfirmed
        }
        XCTAssertEqual(prompt, .unknown)
        let result = try await PreviewLockAction.unlock.perform(current: .unknown, manual: true) {
            XCTFail()
        } unlock: { .needsPasscode }
        XCTAssertEqual(result, .missingPasscode)
    }

    func testMissingPasscodePromptsAndUnconfirmedUnlockIsReported() async throws {
        for (result, expected) in [(DeviceUnlockResult.needsPasscode, PreviewLockNotice.missingPasscode),
                                   (.unconfirmed, .message(DeviceUnlockResult.unconfirmed.displayMessage))] {
            let prompt = try await PreviewLockAction.unlock.perform(current: .locked, manual: false) {
                XCTFail()
            } unlock: { result }
            XCTAssertEqual(prompt, expected)
        }
    }
}
