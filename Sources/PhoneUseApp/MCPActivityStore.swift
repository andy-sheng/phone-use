import Foundation
import Combine
import PhoneUseMCP

/// Session-only history at the app's MCP boundary. Does not persist arguments or image data.
@MainActor
final class MCPActivityStore: ObservableObject {
    struct Call: Identifiable {
        enum State { case running, succeeded, failed }
        let id: UUID
        let name: String
        let device: String
        let arguments: String
        let startedAt: Date
        var state: State = .running
        var elapsed: TimeInterval?
        var result = ""
    }

    @Published private(set) var calls: [Call] = []
    private let capacity: Int
    init(capacity: Int = 200) { self.capacity = max(1, capacity) }

    func clear() { calls.removeAll() }

    /// Keeps the original reply unchanged; UUIDs distinguish equal request IDs across clients.
    func handle(line: Data, operation: @Sendable (Data) async -> Data?) async -> Data? {
        guard let request = MCPServer.decode(line), request["id"] != nil,
              request["method"] as? String == "tools/call" else {
            return await operation(line)
        }
        let params = request["params"] as? [String: Any] ?? [:]
        let args = params["arguments"] as? [String: Any] ?? [:]
        let token = UUID()
        let start = ProcessInfo.processInfo.systemUptime
        calls.insert(Call(id: token, name: Self.bounded(params["name"] as? String ?? "未知工具", limit: 200),
                          device: Self.bounded(args["device"] as? String ?? "自动选择设备", limit: 300),
                          arguments: Self.json(params["arguments"] ?? [:]), startedAt: Date()), at: 0)
        if calls.count > capacity { calls.removeLast(calls.count - capacity) }

        let reply = await operation(line)
        // A cleared or evicted call must not reappear when its reply arrives.
        if let index = calls.firstIndex(where: { $0.id == token }) {
            let message = reply.flatMap(MCPServer.decode)
            let result = message?["result"] as? [String: Any]
            let failed = message == nil || message?["error"] != nil || result == nil || result?["isError"] as? Bool == true
            calls[index].state = failed ? .failed : .succeeded
            calls[index].elapsed = ProcessInfo.processInfo.systemUptime - start
            calls[index].result = Self.summary(message)
        }
        return reply
    }

    private static func summary(_ message: [String: Any]?) -> String {
        guard let message else { return "调用结束，但未收到有效响应。" }
        if let error = message["error"] { return json(error) }
        guard let result = message["result"] as? [String: Any] else { return "响应缺少工具结果。" }
        var parts: [String] = []
        var remaining = 12_000
        for item in result["content"] as? [[String: Any]] ?? [] {
            guard remaining > 0 else { parts.append("…（结果已截断）"); break }
            let part: String
            switch item["type"] as? String {
            case "text": part = bounded(item["text"] as? String ?? "", limit: remaining)
            case "image": part = "[截图 · \(item["mimeType"] as? String ?? "image")]"
            default: part = "[\(item["type"] as? String ?? "内容")]"
            }
            parts.append(part)
            remaining -= part.count
        }
        return parts.isEmpty ? "调用完成，无文本结果。" : parts.joined(separator: "\n")
    }

    private static func json(_ value: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys, .fragmentsAllowed]),
              let text = String(data: data, encoding: .utf8) else { return "无法显示参数" }
        return bounded(text, limit: 8_000)
    }

    private static func bounded(_ text: String, limit: Int) -> String {
        let prefix = text.prefix(limit)
        return prefix.endIndex == text.endIndex ? text : String(prefix) + "\n…（已截断）"
    }
}
