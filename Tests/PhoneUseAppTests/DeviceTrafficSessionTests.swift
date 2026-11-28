import Foundation
import PhoneUseKit
import XCTest
@testable import PhoneUseApp

@MainActor
final class DeviceTrafficSessionTests: XCTestCase {
    private final class FakeDaemon: @unchecked Sendable {
        private let lock = NSLock()
        private var replies: [String]
        private(set) var calls: [(String, DeviceTrafficAction, Int)] = []

        init(_ replies: [String]) { self.replies = replies }

        func respond(_ device: DeviceSummary, _ action: DeviceTrafficAction, _ cursor: Int) throws -> DeviceTrafficSnapshot {
            let reply: String = lock.withLock {
                calls.append((device.udid, action, cursor))
                return replies.count > 1 ? replies.removeFirst() : replies[0]
            }
            return try JSONDecoder().decode(DeviceTrafficSnapshot.self, from: Data(reply.utf8))
        }

        var recorded: [(String, DeviceTrafficAction, Int)] { lock.withLock { calls } }
    }

    private func device(_ udid: String) throws -> DeviceSummary {
        let json = #"{"udid":"\#(udid)","platform":"ios","connection":"usb","name":"iPhone","state":"ready","session":"open"}"#
        return try JSONDecoder().decode(DeviceSummary.self, from: Data(json.utf8))
    }

    private static func flow(_ id: Int, received: Int = 0, closed: Bool = false, requests: String = "[]") -> String {
        #"{"id":\#(id),"process":"nsurlsessiond","pid":90,"app":"Shop","interface":"en","protocol":"tcp","kind":"tls","host":"api.example.com","remote":"93.184.216.34","remotePort":443,"localPort":\#(52000 + id),"firstSeen":100,"lastSeen":101,"sent":10,"received":\#(received),"packets":3,"closed":\#(closed),"requests":\#(requests)}"#
    }

    private static func snapshot(_ session: String, running: Bool, cursor: Int, flows: [String], error: String? = nil) -> String {
        let failure = error.map { #""\#($0)""# } ?? "null"
        return #"{"session":"\#(session)","running":\#(running),"error":\#(failure),"packets":7,"flows":[\#(flows.joined(separator: ","))],"nextCursor":\#(cursor),"hasMore":false}"#
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition() && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(condition())
    }

    func testPollingMergesChangedFlowsAndStopsWithCapture() async throws {
        let http = #"[{"method":"GET","url":"http://plain.example.org/a","status":200}]"#
        let daemon = FakeDaemon([
            Self.snapshot("s1", running: false, cursor: 0, flows: []),
            Self.snapshot("s1", running: true, cursor: 2, flows: [Self.flow(1), Self.flow(2)]),
            Self.snapshot("s1", running: true, cursor: 3, flows: [Self.flow(1, received: 900, closed: true, requests: http)]),
            Self.snapshot("s1", running: false, cursor: 3, flows: [], error: "设备结束了抓包"),
        ])
        let traffic = DeviceTrafficSession(interval: .milliseconds(1)) { try daemon.respond($0, $1, $2) }
        await traffic.attach(try device("phone-a"))
        XCTAssertFalse(traffic.running)
        traffic.start()
        try await waitUntil { traffic.status == "设备结束了抓包" }
        XCTAssertFalse(traffic.running)
        XCTAssertEqual(traffic.flows.map(\.id), [2, 1])
        let updated = try XCTUnwrap(traffic.flows.last)
        XCTAssertEqual(updated.received, 900)
        XCTAssertTrue(updated.closed)
        XCTAssertEqual(updated.requests.first?.status, 200)
        XCTAssertEqual(daemon.recorded.map(\.1), [.read, .start, .read, .read])
        XCTAssertEqual(daemon.recorded.map(\.2), [0, 0, 2, 3])
    }

    func testNewSessionReplacesFlowsAndSelectionChangeStopsPreviousDevice() async throws {
        let daemon = FakeDaemon([
            Self.snapshot("s1", running: true, cursor: 5, flows: [Self.flow(4)]),
            Self.snapshot("s2", running: true, cursor: 1, flows: [Self.flow(1)]),
        ])
        let traffic = DeviceTrafficSession(interval: .seconds(60)) { try daemon.respond($0, $1, $2) }
        await traffic.attach(try device("phone-a"))
        XCTAssertEqual(traffic.flows.map(\.id), [4])
        traffic.clear()
        try await waitUntil { traffic.flows.map(\.id) == [1] }
        traffic.endSelection(except: "phone-a")
        XCTAssertEqual(traffic.device?.udid, "phone-a")
        traffic.endSelection(except: "phone-b")
        XCTAssertNil(traffic.device)
        XCTAssertTrue(traffic.flows.isEmpty)
        try await waitUntil { daemon.recorded.last?.1 == .stop }
        XCTAssertEqual(daemon.recorded.last?.0, "phone-a")
    }
}
