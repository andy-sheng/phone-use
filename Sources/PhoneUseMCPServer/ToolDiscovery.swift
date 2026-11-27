import Foundation
import PhoneUseMCP

/// The default stdio surface stays small even in clients that cache tools/list.
struct ToolDiscovery {
    typealias Definition = [String: Any]
    private static let core = ["list_devices", "select_device", "connect_device", "describe_ui", "screenshot"]
    private static let groups = ["device", "simulator", "input", "apps", "capture", "webkit", "chrome"]
    private let all: [Definition]
    private let byName: [String: Definition]
    let advertised: [Definition]
    let compact: Bool

    init(tools: [Definition], full: Bool) {
        compact = !full
        all = tools
        let index = Dictionary(uniqueKeysWithValues: tools.compactMap { tool in
            (tool["name"] as? String).map { ($0, tool) }
        })
        byName = index
        advertised = full ? tools : Self.core.compactMap { index[$0] } + [Self.search, Self.run]
    }

    private static let search: Definition = [
        "name": "search_tools",
        "description": "Discover PhoneUse operations. With no arguments, list groups. Search by English keywords, group or tool name. An exact name returns its input schema for run_tool.",
        "inputSchema": ["type": "object", "additionalProperties": false, "properties": [
            "query": ["type": "string"], "group": ["type": "string", "enum": groups],
            "offset": ["type": "integer", "minimum": 0]]],
        "annotations": ["readOnlyHint": true, "openWorldHint": false]
    ]
    private static let run: Definition = [
        "name": "run_tool",
        "description": "Execute a PhoneUse or Chrome operation by exact name, with arguments from search_tools. The operation can modify the device or files.",
        "inputSchema": ["type": "object", "additionalProperties": false, "required": ["name", "arguments"],
                        "properties": ["name": ["type": "string"], "arguments": ["type": "object"]]],
        "annotations": ["readOnlyHint": false, "destructiveHint": true, "idempotentHint": false, "openWorldHint": true]
    ]

    private static func group(_ name: String) -> String {
        if name.hasPrefix("chrome_") { return "chrome" }
        if name == "get_web_preview" || name.contains("recording") || name == "screenshot" { return "capture" }
        if name.contains("_web_") { return "webkit" }
        if name.contains("simulator") { return "simulator" }
        if name.contains("sandbox") || name.hasSuffix("_app") || name == "list_apps" { return "apps" }
        if ["describe_ui", "tap", "long_press", "swipe", "gesture", "touch_path", "button", "type_text"].contains(name) { return "input" }
        return "device"
    }

    enum Route {
        case forward(Data)
        case reply([String: Any])
    }

    func route(_ line: Data) -> Route {
        guard var message = MCPServer.decode(line), let id = message["id"] else { return .forward(line) }
        switch message["method"] as? String {
        case "tools/list":
            return .reply(["jsonrpc": "2.0", "id": id, "result": ["tools": advertised]])
        case "tools/call" where compact:
            guard var params = message["params"] as? Definition, let name = params["name"] as? String,
                  name == "search_tools" || name == "run_tool" else { return .forward(line) }
            guard let args = (params["arguments"] ?? Definition()) as? Definition else {
                return .reply(MCPServer.toolError(id: id, "Tool arguments must be an object."))
            }
            if name == "search_tools" { return .reply(searchReply(id: id, args: args)) }
            guard args.count == 2, let operation = args["name"] as? String, byName[operation] != nil,
                  let arguments = args["arguments"] as? Definition else {
                return .reply(MCPServer.toolError(id: id, "Use an exact operation name from search_tools and an arguments object."))
            }
            // Keep the original request ID, metadata and the target tool's normal validation.
            params["name"] = operation
            params["arguments"] = arguments
            message["params"] = params
            guard let encoded = MCPServer.encode(message) else { return .reply(MCPServer.toolError(id: id, "Invalid tool call.")) }
            return .forward(encoded)
        default:
            return .forward(line)
        }
    }

    private func searchReply(id: Any, args: Definition) -> Definition {
        guard Set(args.keys).isSubset(of: ["query", "group", "offset"]),
              let query = (args["query"] ?? "") as? String,
              args["group"] == nil || Self.groups.contains(args["group"] as? String ?? ""),
              let offset = (args["offset"] ?? 0) as? Int, offset >= 0,
              (args["offset"] as? NSNumber).map({ CFGetTypeID($0) != CFBooleanGetTypeID() }) ?? true else {
            return MCPServer.toolError(id: id, "Supply an optional query, listed group and nonnegative integer offset.")
        }
        let group = args["group"] as? String
        let words = query.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
        let result: Definition
        if words.isEmpty && group == nil {
            result = ["groups": Dictionary(grouping: byName.keys, by: Self.group).mapValues(\.count)]
        } else if let name = byName[query], group == nil || group == Self.group(query) {
            result = ["tool": name]
        } else {
            let matches = all.compactMap { tool -> (String, Int, Definition)? in
                guard let name = tool["name"] as? String, group == nil || group == Self.group(name) else { return nil }
                let description = tool["description"] as? String ?? ""
                let text = (name + " " + Self.group(name) + " " + description).lowercased()
                guard words.allSatisfy({ text.contains($0) }) else { return nil }
                let score = words.filter { name.contains($0) }.count
                return (name, score, tool)
            }.sorted { $0.1 == $1.1 ? $0.0 < $1.0 : $0.1 > $1.1 }
            if matches.count == 1 && offset == 0 {
                result = ["tool": matches[0].2]
            } else {
                let batch = matches.dropFirst(min(offset, matches.count)).prefix(8)
                var page: Definition = ["total": matches.count, "matches": batch.map { item in
                    ["name": item.0, "description": item.2["description"] as? String ?? ""]
                }]
                if offset < matches.count - batch.count { page["next_offset"] = offset + batch.count }
                result = page
            }
        }
        guard let data = MCPServer.encode(result) else { return MCPServer.toolError(id: id, "Invalid tool definition.") }
        return ["jsonrpc": "2.0", "id": id, "result": ["content": [["type": "text", "text": String(decoding: data, as: UTF8.self)]]]]
    }
}
