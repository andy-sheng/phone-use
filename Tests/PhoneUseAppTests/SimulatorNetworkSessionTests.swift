import Foundation
import XCTest
@testable import PhoneUseApp

@MainActor
final class SimulatorNetworkSessionTests: XCTestCase {
    func testRequestIsVisibleBeforeHelperClosesItsPipe() async throws {
        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: "/bin/sh")
        helper.arguments = ["-c", #"""
            printf '%s\n' '{"event":"attached"}' '{"event":"launched"}'
            printf '%s' '{"event":"request","method":"GET"'
            sleep 0.1
            printf '%s\n' ',"url":"https://example.test/a","status":200,"millis":75,"received":5,"sent":0}'
            cat >/dev/null
            """#]
        let monitor = SimulatorNetworkSession()
        try monitor.launch(helper, bundle: "example.test")
        defer { monitor.stop() }
        let deadline = ContinuousClock.now + .seconds(5)
        while monitor.requests.isEmpty && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let request = try XCTUnwrap(monitor.requests.first)
        XCTAssertTrue(monitor.active)
        XCTAssertTrue(helper.isRunning)
        XCTAssertEqual(monitor.status, "已连接，正在记录请求")
        XCTAssertEqual(request.url, "https://example.test/a")
        XCTAssertEqual(request.millis, 75)
        monitor.endSelection()
        XCTAssertTrue(monitor.requests.isEmpty)
        let stopDeadline = ContinuousClock.now + .seconds(5)
        while monitor.active && ContinuousClock.now < stopDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(monitor.active)
        XCTAssertEqual(monitor.status, "已结束")
    }
}
