import Foundation
import XCTest
@testable import PhoneUseCLI

final class WebPreviewHTTPTests: XCTestCase {
    func testPostWaitsForCompleteBodyAndChecksInputCredentials() throws {
        let body = Data(#"{"action":"press","button":"home"}"#.utf8)
        let header = Data("POST /input HTTP/1.1\r\nHost: 127.0.0.1:8765\r\nOrigin: http://127.0.0.1:8765\r\nContent-Type: application/json\r\nX-PhoneUse-Token: secret\r\nContent-Length: \(body.count)\r\n\r\n".utf8)
        XCTAssertNil(try WebPreviewHTTP.parse(header + body.prefix(3), port: 8765))
        let request = try XCTUnwrap(WebPreviewHTTP.parse(header + body, port: 8765))
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.path, "/input")
        XCTAssertEqual(request.body, body)
        XCTAssertTrue(request.authorizesInput(token: "secret"))
        XCTAssertFalse(request.authorizesInput(token: "different"))
        for (key, value) in [("origin", "https://untrusted.example"), ("origin", "null"),
                             ("content-type", "text/plain"), ("x-phoneuse-token", "")] {
            var headers = request.headers
            headers[key] = value
            XCTAssertFalse(WebPreviewHTTP.Request(method: "POST", path: "/input", headers: headers, body: body).authorizesInput(token: "secret"))
        }
    }

    func testAmbiguousAndOversizedBodiesAreRejected() {
        for fields in ["Content-Length: -1", "Content-Length: 8193", "Content-Length: 0\r\nContent-Length: 0",
                       "Content-Length: 0\r\nTransfer-Encoding: chunked", "Content-Length: xyz", ""] {
            let data = Data("POST /input HTTP/1.1\r\nHost: localhost:8765\r\n\(fields)\r\n\r\n".utf8)
            XCTAssertThrowsError(try WebPreviewHTTP.parse(data, port: 8765))
        }
        XCTAssertThrowsError(try WebPreviewHTTP.parse(Data(repeating: 65, count: 16385), port: 8765))
        XCTAssertThrowsError(try WebPreviewHTTP.parse(Data("POST /input HTTP/1.1\r\nHost: localhost:8765\r\nContent-Length: 0\r\n\r\nextra".utf8), port: 8765))
    }

    func testAcceptsLocalRequestsAndRejectsRebindingAndMutations() {
        func route(_ request: String) -> String? {
            WebPreviewHTTP.route(Data(request.utf8), port: 8765)
        }
        XCTAssertEqual(route("GET /stream.mjpeg HTTP/1.1\r\nHost: 127.0.0.1:8765\r\n\r\n"), "/stream.mjpeg")
        XCTAssertEqual(route("GET / HTTP/1.1\r\nhost: localhost:8765\r\n\r\n"), "/")
        XCTAssertNil(route("GET / HTTP/1.1\r\nHost: attacker.example:8765\r\n\r\n"))
        XCTAssertNil(route("GET / HTTP/1.1\r\nHost: localhost:8765\r\nHost: attacker.example\r\n\r\n"))
        XCTAssertNil(route("POST / HTTP/1.1\r\nHost: localhost:8765\r\n\r\n"))
        XCTAssertNil(route("GET / HTTP/1.1\r\n\r\n"))
    }

    func testMultipartRetainsBinaryBytesAndExactLength() {
        let jpeg = Data([0xff, 0xd8, 0x00, 0xff, 0xd9])
        let part = WebPreviewHTTP.frame(jpeg)
        let header = Data("--phoneuse-frame\r\nContent-Type: image/jpeg\r\nContent-Length: 5\r\n\r\n".utf8)
        XCTAssertEqual(part, header + jpeg + Data("\r\n".utf8))
        let response = WebPreviewHTTP.response("200 OK", type: "image/jpeg", body: jpeg)
        XCTAssertTrue(response.starts(with: Data("HTTP/1.1 200 OK\r\n".utf8)))
        XCTAssertTrue(response.suffix(jpeg.count) == jpeg)
    }
}
