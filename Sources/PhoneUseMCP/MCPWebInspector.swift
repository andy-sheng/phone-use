import Foundation
import PhoneUseKit

extension MCPCommand {
    static func inspectorRequest(_ name: String, _ args: [String: Any]) throws -> DaemonClient.WebInspectorRequest {
        switch name {
        case "list_web_pages": return .list
        case "attach_web_page": return .attach(page: try string(args, "page_id")!)
        case "describe_web_protocol": return .catalog(domain: try string(args, "domain", optional: true))
        default: break
        }
        let session = try string(args, "session_id")!
        guard UUID(uuidString: session) != nil else {
            throw ToolFailure(message: "Use the session_id returned by attach_web_page.")
        }
        func integer(_ key: String, minimum: Int = 0) throws -> Int {
            let value = args[key] == nil && minimum == 0 ? 0 : try number(args, key)
            guard (Double(minimum)...9_007_199_254_740_991).contains(value), value.rounded() == value else {
                throw ToolFailure(message: "'\(key)' must be an integer of at least \(minimum).")
            }
            return Int(value)
        }
        func command(_ method: String, _ params: [String: Any] = [:], target: String? = nil) throws -> DaemonClient.WebInspectorRequest {
            let data = try JSONSerialization.data(withJSONObject: params, options: .withoutEscapingSlashes)
            guard data.count <= 24 * 1024 else { throw ToolFailure(message: "Inspector params exceed 24 KiB.") }
            return .command(session: session, method: method, parameters: data, target: target)
        }
        switch name {
        case "evaluate_web_javascript":
            let expression = try string(args, "expression")!
            guard expression.utf8.count <= 8192 else { throw ToolFailure(message: "Expression exceeds 8192 UTF-8 bytes.") }
            return .evaluate(session: session, expression: expression)
        case "read_web_console": return .logs(session: session, after: try integer("after"))
        case "detach_web_page": return .detach(session: session)
        case "read_web_data": return .data(session: session, id: try string(args, "data_id")!, offset: try integer("offset"))
        case "read_web_events": return .events(session: session, after: try integer("after"), domain: try string(args, "domain", optional: true))
        case "get_web_dom": return try command("DOM.getDocument")
        case "get_web_css_styles": return try command("CSS.getComputedStyleForNode", ["nodeId": integer("node_id", minimum: 1)])
        case "start_web_network": return try command("Network.enable")
        case "get_web_response_body": return try command("Network.getResponseBody", ["requestId": string(args, "request_id")!])
        case "reload_web_page": return try command("Page.reload")
        case "send_web_command":
            let method = try string(args, "method")!
            guard method.utf8.count <= 200, method.range(of: #"^[A-Za-z][A-Za-z0-9]*\.[A-Za-z][A-Za-z0-9]*$"#, options: .regularExpression) != nil,
                  args["params"] == nil || args["params"] is [String: Any] else {
                throw ToolFailure(message: "Supply a WebKit Domain.command and a JSON object for params.")
            }
            return try command(method, args["params"] as? [String: Any] ?? [:], target: string(args, "target", optional: true))
        default: throw ToolFailure(message: "Unknown Web Inspector operation.")
        }
    }
}
