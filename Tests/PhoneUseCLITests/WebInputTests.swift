import Foundation
import XCTest
@testable import PhoneUseCLI

final class WebInputTests: XCTestCase {
    func testSupportedGesturesAndButtons() throws {
        func decode(_ json: String) throws -> WebInputCommand { try .decode(Data(json.utf8)) }
        XCTAssertEqual(try decode(#"{"action":"tap","x":0.25,"y":0.75,"aspect":0.5}"#), .tap(0.25, 0.75, aspect: 0.5))
        XCTAssertEqual(try decode(#"{"action":"longpress","x":0,"y":1,"duration":800,"aspect":0.5}"#), .longPress(0, 1, milliseconds: 800, aspect: 0.5))
        XCTAssertEqual(try decode(#"{"action":"swipe","x":0,"y":1,"toX":1,"toY":0,"duration":300,"aspect":0.5}"#),
                       .swipe(0, 1, 1, 0, milliseconds: 300, aspect: 0.5))
        XCTAssertEqual(try decode(#"{"action":"press","button":"home"}"#), .press(.home))
        XCTAssertEqual(try decode(#"{"action":"press","button":"back"}"#), .press(.back))
    }

    func testRejectsInvalidCoordinatesDurationsAndActions() {
        let inputs = [
            #"{"action":"tap","x":-0.1,"y":0.5,"aspect":0.5}"#,
            #"{"action":"tap","x":0.5,"y":1.1,"aspect":0.5}"#,
            #"{"action":"tap","x":0.5,"y":0.5}"#,
            #"{"action":"tap","x":true,"y":0.5,"aspect":0.5}"#,
            #"{"action":"tap","x":1e999,"y":0.5,"aspect":0.5}"#,
            #"{"action":"longpress","x":0.5,"y":0.5,"duration":2001,"aspect":0.5}"#,
            #"{"action":"swipe","x":0.5,"y":0.5,"toX":0,"toY":0,"duration":0,"aspect":0.5}"#,
            #"{"action":"press","button":"unknown"}"#,
            #"{"action":"shell","command":"test"}"#,
        ]
        for json in inputs { XCTAssertThrowsError(try WebInputCommand.decode(Data(json.utf8)), json) }
    }
}
