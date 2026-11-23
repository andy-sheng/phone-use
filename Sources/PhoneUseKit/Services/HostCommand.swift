import Foundation

enum HostCommand {
    static func run(_ executable: String, _ arguments: [String], environment: [String: String] = [:]) async throws -> Data {
        let process = Process()
        let output = Pipe()
        let errors = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { $1 }
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = errors
        let finished = ProcessTermination(process)
        try Task.checkCancellation()
        try process.run()
        return try await withTaskCancellationHandler {
            // Drain both pipes so a chatty child can never block on a full buffer.
            async let stdout = Task.detached { output.fileHandleForReading.readDataToEndOfFile() }.value
            async let stderr = Task.detached { errors.fileHandleForReading.readDataToEndOfFile() }.value
            let (data, message) = await (stdout, stderr)
            let status = await finished.wait()
            try Task.checkCancellation()
            guard status == 0 else {
                let detail = String(decoding: message, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                throw DeviceHubError.serviceFailed(detail.isEmpty ? "\(process.executableURL!.lastPathComponent) failed (exit \(status))" : detail)
            }
            return data
        } onCancel: {
            // Stop only the command this request started.
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
    }
}
