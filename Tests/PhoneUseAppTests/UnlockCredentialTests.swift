import XCTest
@testable import PhoneUseApp

final class UnlockCredentialTests: XCTestCase {
    func testLocalCredentialIsPerDeviceAndFailedAttemptsStayReserved() throws {
        let item = UnlockCredential(deviceID: "test-" + UUID().uuidString)
        let other = UnlockCredential(deviceID: "test-" + UUID().uuidString)
        defer { try? item.remove() }
        XCTAssertNil(try item.savedPIN())
        XCTAssertNil(try item.reserve())
        XCTAssertThrowsError(try item.save("code"))
        try item.save("012345")
        XCTAssertEqual(try item.savedPIN(), "012345")
        XCTAssertNil(try other.savedPIN())
        XCTAssertNil(try other.reserve())
        XCTAssertEqual(try item.reserve(), "012345")
        XCTAssertEqual(try item.savedPIN(), "012345")
        XCTAssertThrowsError(try UnlockCredential(deviceID: item.deviceID).reserve())
        try item.setPending(false)
        XCTAssertEqual(try item.reserve(), "012345")
        try item.save("0012")
        XCTAssertEqual(try item.reserve(), "0012")
        try item.remove()
        XCTAssertNil(try item.savedPIN())
        XCTAssertNil(try item.reserve())
    }
}
