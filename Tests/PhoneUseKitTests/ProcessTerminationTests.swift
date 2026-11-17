import Foundation
import XCTest
@testable import PhoneUseKit

final class ProcessTerminationTests: XCTestCase {
    func testAlreadyCancelledTaskWaitsPastPipeEOFForProcessExit() async throws {
        try await checkCancellation(alreadyCancelled: true)
    }

    func testCancellationWhileWaitingDoesNotReportRunningProcessAsFinished() async throws {
        try await checkCancellation(alreadyCancelled: false)
    }

    private func checkCancellation(alreadyCancelled: Bool) async throws {
        let process = Process()
        let input = Pipe()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        // Close output before exiting, as tools may do during shutdown. Keep the
        // process alive on stdin until the test explicitly permits it to exit.
        process.arguments = ["-c", "exec 1>&- 2>&-; read line; exit 7"]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        let termination = ProcessTermination(process)
        try process.run()
        defer {
            try? input.fileHandleForWriting.close()
            if process.isRunning { process.terminate() }
        }
        _ = await Task.detached { output.fileHandleForReading.readDataToEndOfFile() }.value
        XCTAssertTrue(process.isRunning, "Pipe EOF must not be mistaken for process exit")

        let entered = expectation(description: "Entered wait")
        let prematureExit = expectation(description: "Must not finish while process is running")
        prematureExit.isInverted = true
        let waiter = Task {
            if alreadyCancelled { withUnsafeCurrentTask { $0?.cancel() } }
            entered.fulfill()
            let status = await termination.wait()
            if process.isRunning { prematureExit.fulfill() }
            return status
        }
        await fulfillment(of: [entered], timeout: 2)
        waiter.cancel()
        await fulfillment(of: [prematureExit], timeout: 0.1)

        try input.fileHandleForWriting.close()
        let status = await waiter.value
        XCTAssertEqual(status, 7)
        XCTAssertFalse(process.isRunning)
        // Late and repeated waiters must also receive the cached exit status.
        let repeatedStatus = await termination.wait()
        XCTAssertEqual(repeatedStatus, 7)
    }
}
