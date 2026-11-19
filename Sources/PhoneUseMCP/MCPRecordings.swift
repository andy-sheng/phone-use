import Foundation
import PhoneUseKit

/// Shared by all bridge connections in the host. Each ID owns one start and one finalization.
@MainActor
final class MCPRecordings {
    struct Movie {
        let id: UUID
        let device: String
        let url: URL

        var metadata: [String: Any] {
            ["recording_id": id.uuidString, "device": device, "local_path": url.path]
        }
    }

    private struct Entry {
        let movie: Movie
        let start: Task<any ScreenRecordingSession, Error>
        var stop: Task<URL, Error>?
    }

    private var entries: [UUID: Entry] = [:]
    private var closing = false
    private let directory: URL

    nonisolated init(directory: URL = PhoneUseConfiguration.current.supportDirectory.appendingPathComponent("Recordings")) {
        self.directory = directory
    }

    func start(device: String, capture: @escaping @Sendable (URL) async throws -> any ScreenRecordingSession) async throws -> Movie {
        guard !closing else { throw ToolFailure(message: "PhoneUse is quitting.") }
        if let existing = entries.values.first(where: { $0.movie.device == device }) {
            throw ToolFailure(message: "This device already has recording \(existing.movie.id). Finish it with stop_recording.")
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let id = UUID()
        let movie = Movie(id: id, device: device, url: directory.appendingPathComponent("\(id).mp4"))
        let task = Task { try await capture(movie.url) }
        entries[id] = Entry(movie: movie, start: task)
        do {
            _ = try await task.value
            return movie
        } catch {
            entries[id] = nil
            throw error
        }
    }

    func stop(_ id: UUID) async throws -> Movie {
        guard let entry = entries[id] else { throw ToolFailure(message: "No active recording with ID \(id).") }
        defer { entries[id] = nil }
        let task: Task<URL, Error>
        if let existing = entry.stop {
            task = existing
        } else {
            task = Task { try await entry.start.value.stop() }
            entries[id]?.stop = task
        }
        _ = try await task.value
        return entry.movie
    }

    func finish(for device: String) async throws -> Movie? {
        guard let entry = entries.values.first(where: { $0.movie.device == device }) else { return nil }
        return try await stop(entry.movie.id)
    }

    func finishBeforeTermination() -> Task<Void, Never>? {
        closing = true
        let ids = Array(entries.keys)
        guard !ids.isEmpty else { return nil }
        return Task {
            for id in ids {
                do { _ = try await stop(id) }
                catch { Diagnostics.record("mcp.recording.stop.failed", ["error": String(describing: error)]) }
            }
        }
    }
}
