import Foundation
import Combine
import Network
import Darwin

/// A local-network bridge for Workspace-owned files. The server is deliberately
/// limited to the Documents/Workspace Files root: callers can inspect and
/// rearrange project assets, but cannot run commands or access another app's
/// sandbox.
@MainActor
final class WorkspaceMCPServer: ObservableObject {
    static let shared = WorkspaceMCPServer()

    @Published private(set) var isRunning = false
    @Published private(set) var endpoint: URL?
    @Published private(set) var statusMessage = "Stopped"
    @Published private(set) var requestCount = 0
    @Published private(set) var accessToken: String

    /// The bridge keeps a bounded, in-memory audit trail. It is deliberately
    /// metadata-only: request bodies are never persisted so credentials and
    /// private file contents cannot leak through the diagnostic endpoint.
    @Published private(set) var readOnlyMode = false
    @Published private(set) var dangerousMode = false

    private let tokenDefaultsKey = "workspace.mcp.accessToken.v1"
    private var listener: NWListener?
    private var rootDirectory: URL?
    private let fileManager = FileManager.default
    private var actionHistory: [[String: Any]] = []
    private var eventHistory: [[String: Any]] = []
    private let maxHistory = 250

    private static let capabilityUnavailableTools: Set<String> = [
        "guest_view_inspect", "guest_view_tree",
        "guest_visible_text", "guest_ocr", "guest_keyboard_state",
        "guest_wait_until", "guest_wait_for_text", "guest_wait_for_element",
        "guest_assert", "guest_drag",
        "guest_pinch", "guest_rotate",
        "guest_list", "guest_launch", "guest_stop", "guest_restart", "guest_task_list",
        "guest_task_switch", "guest_task_close", "guest_fs_list", "guest_fs_read",
        "guest_fs_write", "guest_fs_search", "guest_script_load", "guest_script_unload",
        "guest_objc_classes", "guest_objc_methods", "guest_modules", "guest_exports",
        "guest_hook_method", "guest_unhook_method", "guest_memory_read",
        "repo_add", "repo_refresh", "repo_search", "ipa_inspect", "sign_ipa",
        "github_actions_dispatch", "pi_exec", "workflow_create", "workflow_run"
    ]

    private static let aliases: [String: String] = [
        "screenshot": "guest_screenshot", "click": "guest_tap", "tap": "guest_tap",
        "type": "guest_type", "keypress": "guest_key", "key": "guest_key",
        "scroll": "guest_swipe", "drag": "guest_drag", "state": "guest_state",
        "logs": "guest_logs", "evaluate": "guest_eval"
    ]

    private static let mutatingTools: Set<String> = [
        "copy_file", "move_file", "delete_file", "make_directory", "guest_tap",
        "guest_swipe", "guest_type", "guest_key", "guest_eval", "guest_fs_write",
        "guest_fs_copy", "guest_fs_move", "guest_fs_delete", "guest_launch", "guest_stop",
        "guest_restart", "guest_task_switch", "guest_task_close", "sign_ipa", "repo_add",
        "repo_remove", "repo_refresh", "workflow_create", "workflow_run", "pi_exec"
    ]

    private static let dangerousTools: Set<String> = [
        "guest_eval", "guest_script_load", "guest_objc_classes", "guest_objc_methods",
        "guest_hook_method", "guest_unhook_method", "guest_memory_read", "sign_ipa", "pi_exec"
    ]

    /// Tool metadata is intentionally plain JSON so it can be consumed by
    /// clients that do not implement the MCP SDK. `availability` allows an AI
    /// client to plan around missing guest instrumentation without guessing.
    private static let toolRegistry: [[String: Any]] = [
        ["name": "list_files", "arguments": ["path"], "read_only": true, "availability": "available"],
        ["name": "read_file", "arguments": ["path"], "read_only": true, "availability": "available"],
        ["name": "copy_file", "arguments": ["source", "destination"], "read_only": false, "availability": "available"],
        ["name": "move_file", "arguments": ["source", "destination"], "read_only": false, "availability": "available"],
        ["name": "delete_file", "arguments": ["path"], "read_only": false, "availability": "available"],
        ["name": "make_directory", "arguments": ["path"], "read_only": false, "availability": "available"],
        ["name": "guest_session", "arguments": [], "read_only": true, "availability": "available"],
        ["name": "guest_state", "arguments": ["snapshot_id", "include_screenshot", "include_tree"], "read_only": true, "availability": "available"],
        ["name": "guest_screenshot", "arguments": ["snapshot_id"], "read_only": true, "availability": "available"],
        ["name": "guest_tap", "arguments": ["snapshot_id", "element_token", "x", "y"], "read_only": false, "availability": "available"],
        ["name": "guest_swipe", "arguments": ["snapshot_id", "from", "to", "duration_ms"], "read_only": false, "availability": "available"],
        ["name": "guest_type", "arguments": ["snapshot_id", "element_token", "text"], "read_only": false, "availability": "available"],
        ["name": "guest_key", "arguments": ["snapshot_id", "key"], "read_only": false, "availability": "available"],
        ["name": "guest_logs", "arguments": [], "read_only": true, "availability": "available"],
        ["name": "guest_eval", "arguments": ["code"], "read_only": false, "availability": "available", "dangerous": true],
        ["name": "bridge_capabilities", "arguments": [], "read_only": true, "availability": "available"],
        ["name": "action_history", "arguments": ["limit"], "read_only": true, "availability": "available"],
        ["name": "action_status", "arguments": ["action_id"], "read_only": true, "availability": "available"],
        ["name": "action_wait", "arguments": ["action_id"], "read_only": true, "availability": "available"],
        ["name": "safety_status", "arguments": [], "read_only": true, "availability": "available"],
        ["name": "safety_configure", "arguments": ["read_only", "dangerous"], "read_only": false, "availability": "available"],
        ["name": "guest_accessibility_snapshot", "arguments": [], "read_only": true, "availability": "available"],
        ["name": "guest_view_inspect", "arguments": ["element_token"], "read_only": true, "availability": "requires_guest_bridge"],
        ["name": "guest_wait_until", "arguments": ["condition", "timeout_ms"], "read_only": true, "availability": "requires_guest_bridge"],
        ["name": "guest_assert", "arguments": ["condition"], "read_only": true, "availability": "requires_guest_bridge"],
        ["name": "guest_clipboard_get", "arguments": [], "read_only": true, "availability": "requires_guest_bridge"],
        ["name": "guest_clipboard_set", "arguments": ["text"], "read_only": false, "availability": "requires_guest_bridge"],
        ["name": "guest_double_tap", "arguments": ["snapshot_id", "element_token", "x", "y"], "read_only": false, "availability": "available"],
        ["name": "guest_long_press", "arguments": ["snapshot_id", "element_token", "x", "y", "duration_ms"], "read_only": false, "availability": "available"],
        ["name": "guest_scroll", "arguments": ["snapshot_id", "from", "to", "duration_ms"], "read_only": false, "availability": "available"],
        ["name": "guest_set_text", "arguments": ["snapshot_id", "element_token", "text"], "read_only": false, "availability": "available"],
        ["name": "guest_focus", "arguments": ["snapshot_id", "element_token"], "read_only": false, "availability": "available"],
        ["name": "guest_keyboard", "arguments": ["snapshot_id", "visible"], "read_only": false, "availability": "available"],
        ["name": "guest_runtime_info", "arguments": ["snapshot_id"], "read_only": true, "availability": "available"],
        ["name": "guest_metrics", "arguments": ["snapshot_id"], "read_only": true, "availability": "available"],
        ["name": "guest_filesystem", "arguments": ["snapshot_id", "operation", "path"], "read_only": false, "availability": "available"],
        ["name": "guest_list", "arguments": [], "read_only": true, "availability": "requires_livecontainer_hooks"],
        ["name": "guest_launch", "arguments": ["bundle_identifier"], "read_only": false, "availability": "requires_livecontainer_hooks"],
        ["name": "guest_task_list", "arguments": [], "read_only": true, "availability": "requires_livecontainer_hooks"],
        ["name": "guest_task_switch", "arguments": ["task_id"], "read_only": false, "availability": "requires_livecontainer_hooks"],
        ["name": "guest_fs_list", "arguments": ["path"], "read_only": true, "availability": "requires_guest_filesystem"],
        ["name": "guest_fs_read", "arguments": ["path"], "read_only": true, "availability": "requires_guest_filesystem"],
        ["name": "guest_fs_write", "arguments": ["path", "content"], "read_only": false, "availability": "requires_guest_filesystem"],
        ["name": "guest_script_load", "arguments": ["code"], "read_only": false, "availability": "requires_guest_bridge", "dangerous": true],
        ["name": "guest_objc_classes", "arguments": [], "read_only": true, "availability": "requires_guest_bridge", "dangerous": true],
        ["name": "guest_hook_method", "arguments": ["class", "selector"], "read_only": false, "availability": "requires_guest_bridge", "dangerous": true],
        ["name": "guest_memory_read", "arguments": ["address", "length"], "read_only": true, "availability": "requires_guest_bridge", "dangerous": true],
        ["name": "guest_metrics", "arguments": [], "read_only": true, "availability": "requires_guest_bridge"],
        ["name": "repo_add", "arguments": ["url"], "read_only": false, "availability": "requires_installer_module"],
        ["name": "repo_refresh", "arguments": [], "read_only": false, "availability": "requires_installer_module"],
        ["name": "repo_search", "arguments": ["query"], "read_only": true, "availability": "requires_installer_module"],
        ["name": "ipa_inspect", "arguments": ["path"], "read_only": true, "availability": "requires_installer_module"],
        ["name": "sign_ipa", "arguments": ["ipa", "p12", "mobileprovision"], "read_only": false, "availability": "requires_signing_module", "dangerous": true],
        ["name": "workflow_create", "arguments": ["steps"], "read_only": false, "availability": "requires_automation_module"],
        ["name": "workflow_run", "arguments": ["workflow_id"], "read_only": false, "availability": "requires_automation_module"],
        ["name": "github_actions_dispatch", "arguments": ["repository", "workflow"], "read_only": false, "availability": "requires_github_module"],
        ["name": "pi_exec", "arguments": ["command"], "read_only": false, "availability": "requires_pi_module", "dangerous": true]
    ]

    private init() {
        let stored = UserDefaults.standard.string(forKey: tokenDefaultsKey)
        accessToken = stored ?? Self.makeToken()
        if stored == nil {
            UserDefaults.standard.set(accessToken, forKey: tokenDefaultsKey)
        }
        readOnlyMode = UserDefaults.standard.bool(forKey: "workspace.mcp.readOnly.v1")
        dangerousMode = UserDefaults.standard.bool(forKey: "workspace.mcp.dangerous.v1")
    }

    func start(rootDirectory: URL, advertiseOnLAN: Bool = false) {
        stop()
        do {
            try fileManager.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
            self.rootDirectory = rootDirectory.resolvingSymlinksInPath().standardizedFileURL
            let listener = try NWListener(using: .tcp, on: .any)
            if !advertiseOnLAN {
                listener.parameters.requiredLocalEndpoint = .hostPort(
                    host: NWEndpoint.Host("127.0.0.1"),
                    port: .any
                )
            }
            listener.stateUpdateHandler = { [weak self, weak listener] state in
                Task { @MainActor in
                    guard let self else { return }
                    switch state {
                    case .ready:
                        guard let port = listener?.port?.rawValue else {
                            self.statusMessage = "The bridge could not acquire a port."
                            return
                        }
                        let host = advertiseOnLAN ? (Self.preferredHostAddress() ?? "127.0.0.1") : "127.0.0.1"
                        self.endpoint = URL(string: "http://\(host):\(port)")
                        self.isRunning = true
                        self.statusMessage = "Listening on \(host):\(port)"
                    case .failed(let error):
                        self.statusMessage = "Bridge stopped: \(error.localizedDescription)"
                        self.stop()
                    case .cancelled:
                        self.isRunning = false
                    default:
                        break
                    }
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor [weak self] in
                    self?.handle(connection)
                }
            }
            self.listener = listener
            listener.start(queue: .global(qos: .userInitiated))
        } catch {
            statusMessage = "Could not start bridge: \(error.localizedDescription)"
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        isRunning = false
        endpoint = nil
        if statusMessage != "Stopped" { statusMessage = "Stopped" }
    }

    func rotateAccessToken() {
        accessToken = Self.makeToken()
        UserDefaults.standard.set(accessToken, forKey: tokenDefaultsKey)
    }

    func setReadOnlyMode(_ enabled: Bool) {
        readOnlyMode = enabled
        UserDefaults.standard.set(enabled, forKey: "workspace.mcp.readOnly.v1")
        appendEvent("safety.changed", details: ["read_only": enabled])
    }

    func setDangerousMode(_ enabled: Bool) {
        dangerousMode = enabled
        UserDefaults.standard.set(enabled, forKey: "workspace.mcp.dangerous.v1")
        appendEvent("safety.changed", details: ["dangerous": enabled])
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: .global(qos: .userInitiated))
        connection.receive(minimumIncompleteLength: 1, maximumLength: 262_144) { [weak self] data, _, _, _ in
            guard let self, let data else {
                connection.cancel()
                return
            }
            Task { @MainActor in
                self.requestCount += 1
                connection.send(content: self.response(for: data), completion: .contentProcessed { _ in
                    connection.cancel()
                })
            }
        }
    }

    private func response(for requestData: Data) -> Data {
        guard let request = String(data: requestData, encoding: .utf8),
              let headerRange = request.range(of: "\r\n\r\n") else {
            return httpResponse(status: "400 Bad Request", body: json(["error": "Malformed HTTP request"]))
        }

        let headerText = String(request[..<headerRange.lowerBound])
        let bodyText = String(request[headerRange.upperBound...])
        let lines = headerText.components(separatedBy: "\r\n")
        guard let start = lines.first?.split(separator: " "), start.count >= 2 else {
            return httpResponse(status: "400 Bad Request", body: json(["error": "Missing request line"]))
        }

        let method = String(start[0])
        let rawPath = String(start[1])
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let split = line.firstIndex(of: ":") else { continue }
            let name = String(line[..<split]).lowercased()
            let value = String(line[line.index(after: split)...]).trimmingCharacters(in: .whitespaces)
            if headers[name] == nil { headers[name] = value }
        }
        let queryParts = rawPath.split(separator: "?", maxSplits: 1)
        let path = queryParts.first.map(String.init) ?? rawPath
        let query = queryParts.count > 1 ? Self.parseQuery(String(queryParts[1])) : [:]

        if path == "/health" && method == "GET" {
            return httpResponse(body: json([
                "name": "Workspace MCP Bridge",
                "status": "ok",
                "tools": Self.toolRegistry.map { $0["name"] as? String ?? "" },
                "request_count": requestCount,
                "safety": ["read_only": readOnlyMode, "dangerous": dangerousMode]
            ]))
        }

        guard headers["authorization"] == "Bearer \(accessToken)" else {
            return httpResponse(status: "401 Unauthorized", body: json(["error": "Bearer token required"]))
        }

        if path == "/capabilities" && method == "GET" {
            return httpResponse(body: json(capabilitiesPayload()))
        }

        if path == "/events" && method == "GET" {
            let limit = min(max(Int(query["limit"] ?? "50") ?? 50, 1), maxHistory)
            return httpResponse(body: json(["events": Array(eventHistory.suffix(limit))]))
        }

        if path == "/actions" && method == "GET" {
            let limit = min(max(Int(query["limit"] ?? "50") ?? 50, 1), maxHistory)
            return httpResponse(body: json(["actions": Array(actionHistory.suffix(limit))]))
        }

        if path == "/action/status" && method == "GET" {
            let id = query["action_id"] ?? ""
            let action = actionHistory.last { ($0["action_id"] as? String) == id }
            return httpResponse(body: json(["action": action ?? NSNull()]))
        }

        if path == "/safety" && method == "GET" {
            return httpResponse(body: json(["read_only": readOnlyMode, "dangerous": dangerousMode]))
        }

        if path == "/safety" && method == "POST",
           let bodyData = bodyText.data(using: .utf8),
           let payload = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any] {
            if let value = payload["read_only"] as? Bool { setReadOnlyMode(value) }
            if let value = payload["dangerous"] as? Bool { setDangerousMode(value) }
            return httpResponse(body: json(["ok": true, "read_only": readOnlyMode, "dangerous": dangerousMode]))
        }

        if path == "/guest/session" && method == "GET" {
            return httpResponse(body: json(WorkspaceGuestSessionStore.shared.snapshot()))
        }

        if path == "/guest/logs" && method == "GET" {
            let session = WorkspaceGuestSessionStore.shared
            let logs = session.logs.map { [
                "id": $0.id.uuidString,
                "date": $0.date.ISO8601Format(),
                "level": $0.level,
                "message": $0.message
            ] }
            return httpResponse(body: json([
                "app": session.appName ?? "",
                "bundleIdentifier": session.bundleIdentifier ?? "",
                "active": session.isActive,
                "logs": logs
            ]))
        }

        if path == "/guest/eval" && method == "POST",
           let bodyData = bodyText.data(using: .utf8),
           let payload = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any],
           let code = payload["code"] as? String,
           !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let session = WorkspaceGuestSessionStore.shared
            guard session.isActive else {
                return httpResponse(status: "409 Conflict", body: json(["error": "No LiveContainer guest is active."]))
            }
            let id = session.submitEvaluation(code)
            return httpResponse(status: "202 Accepted", body: json([
                "id": id.uuidString,
                "status": "queued",
                "note": "The Frida Gadget bridge must consume /guest/pending and post the result to /guest/result."
            ]))
        }

        if path == "/guest/pending" && method == "GET" {
            WorkspaceGuestSessionStore.shared.setBridgeConnected(true)
            let pending = WorkspaceGuestSessionStore.shared.evaluations
                .filter { $0.result == nil && $0.error == nil }
                .map { ["id": $0.id.uuidString, "code": $0.code] }
            return httpResponse(body: json(["evaluations": pending]))
        }

        if path == "/guest/result" && method == "POST",
           let bodyData = bodyText.data(using: .utf8),
           let payload = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any],
           let rawID = payload["id"] as? String,
           let id = UUID(uuidString: rawID) {
            WorkspaceGuestSessionStore.shared.completeEvaluation(
                id: id,
                result: payload["result"] as? String,
                error: payload["error"] as? String
            )
            return httpResponse(body: json(["ok": true]))
        }

        if path == "/guest/log" && method == "POST",
           let bodyData = bodyText.data(using: .utf8),
           let payload = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any],
           let message = payload["message"] as? String {
            if message == "Workspace Frida bridge connected" {
                WorkspaceGuestSessionStore.shared.setBridgeConnected(true)
            }
            WorkspaceGuestSessionStore.shared.appendLog(message, level: payload["level"] as? String ?? "info")
            return httpResponse(body: json(["ok": true]))
        }

        // CUA-style guest control endpoints. All are bearer-token protected
        // above and use the same snapshot-scoped validation as /call.
        if path == "/guest/state" && method == "POST",
           let bodyData = bodyText.data(using: .utf8),
           let arguments = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any] {
            let result = WorkspaceGuestControlCenter.shared.state(arguments: arguments)
            return httpResponse(status: result.status, body: json(result.body))
        }

        if path == "/guest/screenshot" && method == "POST",
           let bodyData = bodyText.data(using: .utf8),
           let arguments = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any] {
            let result = WorkspaceGuestControlCenter.shared.screenshot(arguments: arguments)
            return httpResponse(status: result.status, body: json(result.body))
        }

        if path.hasPrefix("/guest/control/") && method == "POST",
           let bodyData = bodyText.data(using: .utf8),
           let arguments = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any] {
            let name = String(path.dropFirst("/guest/control/".count))
            let tool = "guest_\(name)"
            if ["guest_tap", "guest_swipe", "guest_type", "guest_key",
                "guest_double_tap", "guest_long_press", "guest_scroll",
                "guest_set_text", "guest_focus", "guest_keyboard",
                "guest_clipboard", "guest_accessibility_snapshot",
                "guest_runtime_info", "guest_metrics", "guest_filesystem"].contains(tool) {
                let result = WorkspaceGuestControlCenter.shared.action(tool: tool, arguments: arguments)
                return httpResponse(status: result.status, body: json(result.body))
            }
        }

        if path == "/guest/control/pending" && method == "GET" {
            WorkspaceGuestSessionStore.shared.setBridgeConnected(true)
            return httpResponse(body: json(["commands": WorkspaceGuestSessionStore.shared.pendingControlCommands()]))
        }

        if path == "/guest/control/result" && method == "POST",
           let bodyData = bodyText.data(using: .utf8),
           let payload = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any],
           let rawID = payload["id"] as? String,
           let id = UUID(uuidString: rawID) {
            WorkspaceGuestSessionStore.shared.completeControlCommand(
                id: id,
                result: payload["result"] as? String,
                error: payload["error"] as? String
            )
            return httpResponse(body: json(["ok": true]))
        }

        if path == "/tools" && method == "GET" {
            return httpResponse(body: json(["tools": Self.toolRegistry]))
        }

        guard path == "/call", method == "POST",
              let bodyData = bodyText.data(using: .utf8),
              let payload = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any],
              let tool = payload["tool"] as? String else {
            return httpResponse(status: "404 Not Found", body: json(["error": "Use GET /tools or POST /call"]))
        }

        let arguments = payload["arguments"] as? [String: Any] ?? [:]
        return toolResponse(tool: Self.aliases[tool] ?? tool, arguments: arguments, requestedTool: tool)
    }

    private func toolResponse(tool: String, arguments: [String: Any], requestedTool: String? = nil) -> Data {
        let actionID = UUID().uuidString.lowercased()
        let requested = requestedTool ?? tool
        if tool == "bridge_capabilities" { return httpResponse(body: json(capabilitiesPayload())) }
        if tool == "action_history" {
            let limit = min(max((arguments["limit"] as? NSNumber)?.intValue ?? 50, 1), maxHistory)
            return httpResponse(body: json(["actions": Array(actionHistory.suffix(limit))]))
        }
        if tool == "action_status" || tool == "action_wait" {
            let id = (arguments["action_id"] as? String) ?? ""
            return httpResponse(body: json(["action": actionHistory.last { ($0["action_id"] as? String) == id } ?? NSNull()]))
        }
        if tool == "safety_status" { return httpResponse(body: json(["read_only": readOnlyMode, "dangerous": dangerousMode])) }
        if tool == "safety_configure" {
            if let value = arguments["read_only"] as? Bool { setReadOnlyMode(value) }
            if let value = arguments["dangerous"] as? Bool { setDangerousMode(value) }
            return httpResponse(body: json(["ok": true, "read_only": readOnlyMode, "dangerous": dangerousMode]))
        }
        if readOnlyMode && Self.mutatingTools.contains(tool) {
            let response = httpResponse(status: "403 Forbidden", body: json(["effect": "refused", "refusal_code": "read_only_mode", "message": "The bridge is in read-only mode.", "action_id": actionID]))
            recordAction(id: actionID, requestedTool: requested, tool: tool, status: "refused")
            return response
        }
        if !dangerousMode && Self.dangerousTools.contains(tool) {
            let response = httpResponse(status: "403 Forbidden", body: json(["effect": "refused", "refusal_code": "dangerous_mode_required", "message": "Enable dangerous mode before using this capability.", "action_id": actionID]))
            recordAction(id: actionID, requestedTool: requested, tool: tool, status: "refused")
            return response
        }
        if Self.capabilityUnavailableTools.contains(tool) {
            let response = httpResponse(status: "501 Not Implemented", body: json(["effect": "capability_unavailable", "capability": tool, "action_id": actionID, "message": "This capability requires an opted-in LiveContainer/guest integration that is not available in this build."]))
            recordAction(id: actionID, requestedTool: requested, tool: tool, status: "unavailable")
            return response
        }
        do {
            switch tool {
            case "guest_session":
                let response = httpResponse(body: json(WorkspaceGuestSessionStore.shared.snapshot()))
                recordAction(id: actionID, requestedTool: requested, tool: tool, status: "ok")
                return response

            case "guest_state":
                let response = guestControlResponse(tool: tool, arguments: arguments)
                recordAction(id: actionID, requestedTool: requested, tool: tool, status: "ok")
                return response

            case "guest_screenshot", "guest_tap", "guest_swipe", "guest_type", "guest_key":
                let response = guestControlResponse(tool: tool, arguments: arguments)
                recordAction(id: actionID, requestedTool: requested, tool: tool, status: "queued")
                return response

            case "guest_logs":
                let session = WorkspaceGuestSessionStore.shared
                let logs = session.logs.map { [
                    "id": $0.id.uuidString,
                    "date": $0.date.ISO8601Format(),
                    "level": $0.level,
                    "message": $0.message
                ] }
                return httpResponse(body: json([
                    "app": session.appName ?? "",
                    "bundleIdentifier": session.bundleIdentifier ?? "",
                    "active": session.isActive,
                    "logs": logs
                ]))

            case "guest_eval":
                let code = try requiredArgument("code", in: arguments)
                guard WorkspaceGuestSessionStore.shared.isActive else {
                    throw MCPError.message("No LiveContainer guest is active.")
                }
                let id = WorkspaceGuestSessionStore.shared.submitEvaluation(code)
                return httpResponse(status: "202 Accepted", body: json([
                    "id": id.uuidString,
                    "status": "queued",
                    "next": "/guest/pending"
                ]))

            case "list_files":
                let directory = try securedURL(arguments["path"] as? String ?? "")
                let urls = try fileManager.contentsOfDirectory(
                    at: directory,
                    includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey],
                    options: [.skipsHiddenFiles]
                )
                let items: [[String: Any]] = try urls.sorted { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }.map { url in
                    let values = try url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey])
                    return [
                        "name": url.lastPathComponent,
                        "path": relativePath(for: url),
                        "directory": values.isDirectory ?? false,
                        "size": values.fileSize ?? 0,
                        "modified": values.contentModificationDate?.ISO8601Format() ?? ""
                    ]
                }
                return httpResponse(body: json(["items": items]))

            case "read_file":
                let url = try securedURL(requiredArgument("path", in: arguments))
                let data = try Data(contentsOf: url)
                guard data.count <= 131_072 else {
                    throw MCPError.message("File is larger than the 128 KB read limit.")
                }
                let text = String(data: data, encoding: .utf8) ?? data.base64EncodedString()
                return httpResponse(body: json(["path": relativePath(for: url), "content": text]))

            case "copy_file", "move_file":
                let source = try securedURL(requiredArgument("source", in: arguments))
                let destination = try securedURL(requiredArgument("destination", in: arguments))
                guard fileManager.fileExists(atPath: source.path) else {
                    throw MCPError.message("Source does not exist.")
                }
                guard !fileManager.fileExists(atPath: destination.path) else {
                    throw MCPError.message("Destination already exists.")
                }
                try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                if tool == "copy_file" {
                    try fileManager.copyItem(at: source, to: destination)
                } else {
                    try fileManager.moveItem(at: source, to: destination)
                }
                return httpResponse(body: json(["ok": true, "path": relativePath(for: destination)]))

            case "delete_file":
                let url = try securedURL(requiredArgument("path", in: arguments))
                guard url != rootDirectory else { throw MCPError.message("The Workspace root cannot be deleted.") }
                try fileManager.removeItem(at: url)
                return httpResponse(body: json(["ok": true]))

            case "make_directory":
                let url = try securedURL(requiredArgument("path", in: arguments))
                try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
                return httpResponse(body: json(["ok": true, "path": relativePath(for: url)]))

            default:
                throw MCPError.message("Unknown tool: \(tool)")
            }
        } catch {
            recordAction(id: actionID, requestedTool: requested, tool: tool, status: "error")
            return httpResponse(status: "400 Bad Request", body: json(["effect": "error", "action_id": actionID, "error": error.localizedDescription]))
        }
    }

    private func requiredArgument(_ name: String, in arguments: [String: Any]) throws -> String {
        guard let value = arguments[name] as? String, !value.isEmpty else {
            throw MCPError.message("Missing \(name).")
        }
        return value
    }

    private func securedURL(_ relativePath: String) throws -> URL {
        guard let rootDirectory else { throw MCPError.message("Bridge is not running.") }
        let pieces = relativePath.split(separator: "/", omittingEmptySubsequences: true)
        guard !pieces.contains(".."), !relativePath.hasPrefix("/") else {
            throw MCPError.message("Path must stay inside Workspace Files.")
        }
        let candidate = pieces.reduce(rootDirectory) { partial, piece in
            partial.appendingPathComponent(String(piece), isDirectory: false)
        }.standardizedFileURL
        let resolvedParent = candidate.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL
        let url = (fileManager.fileExists(atPath: candidate.path) ? candidate.resolvingSymlinksInPath() : resolvedParent.appendingPathComponent(candidate.lastPathComponent)).standardizedFileURL
        let root = rootDirectory.path.hasSuffix("/") ? rootDirectory.path : rootDirectory.path + "/"
        guard url == rootDirectory || url.path.hasPrefix(root) else {
            throw MCPError.message("Path must stay inside Workspace Files.")
        }
        return url
    }

    private func relativePath(for url: URL) -> String {
        guard let rootDirectory else { return url.lastPathComponent }
        let root = rootDirectory.path.hasSuffix("/") ? rootDirectory.path : rootDirectory.path + "/"
        if url == rootDirectory { return "" }
        guard url.path.hasPrefix(root) else { return url.lastPathComponent }
        return String(url.path.dropFirst(root.count))
    }

    private func capabilitiesPayload() -> [String: Any] {
        let available = Self.toolRegistry.compactMap { item -> String? in
            guard let name = item["name"] as? String else { return nil }
            return (item["availability"] as? String) == "available" ? name : nil
        }
        let unavailable = Self.toolRegistry.compactMap { item -> [String: Any]? in
            guard let name = item["name"] as? String,
                  let availability = item["availability"] as? String,
                  availability != "available" else { return nil }
            return ["name": name, "reason": availability]
        }
        return [
            "protocol": "workspace-mcp/1",
            "server": "Workspace MCP Bridge",
            "available_tools": available,
            "unavailable_tools": unavailable,
            "aliases": Self.aliases,
            "safety": ["read_only": readOnlyMode, "dangerous": dangerousMode],
            "limits": ["max_history": maxHistory, "max_file_read_bytes": 131_072]
        ]
    }

    private func recordAction(id: String, requestedTool: String, tool: String, status: String) {
        actionHistory.append([
            "action_id": id,
            "requested_tool": requestedTool,
            "tool": tool,
            "status": status,
            "date": Date().ISO8601Format()
        ])
        if actionHistory.count > maxHistory { actionHistory.removeFirst(actionHistory.count - maxHistory) }
        appendEvent("action.(status)", details: ["action_id": id, "tool": tool])
    }

    private func appendEvent(_ name: String, details: [String: Any] = [:]) {
        var event: [String: Any] = ["id": UUID().uuidString.lowercased(), "name": name, "date": Date().ISO8601Format()]
        for (key, value) in details { event[key] = value }
        eventHistory.append(event)
        if eventHistory.count > maxHistory { eventHistory.removeFirst(eventHistory.count - maxHistory) }
    }

    private func json(_ object: Any) -> Data {
        (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{\"error\":\"Encoding failure\"}".utf8)
    }

    private func httpResponse(status: String = "200 OK", body: Data) -> Data {
        var response = Data("HTTP/1.1 \(status)\r\nContent-Type: application/json; charset=utf-8\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8)
        response.append(body)
        return response
    }

    private static func makeToken() -> String {
        UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }

    private static func parseQuery(_ value: String) -> [String: String] {
        value.split(separator: "&").reduce(into: [String: String]()) { result, part in
            let pieces = part.split(separator: "=", maxSplits: 1).map(String.init)
            guard let key = pieces.first, !key.isEmpty else { return }
            result[key] = pieces.count > 1 ? pieces[1].removingPercentEncoding ?? pieces[1] : ""
        }
    }

    private static func preferredHostAddress() -> String? {
        var interfaces: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaces) == 0, let first = interfaces else { return nil }
        defer { freeifaddrs(first) }

        var current: UnsafeMutablePointer<ifaddrs>? = first
        while let interface = current {
            current = interface.pointee.ifa_next
            guard interface.pointee.ifa_flags & UInt32(IFF_UP) != 0,
                  interface.pointee.ifa_flags & UInt32(IFF_LOOPBACK) == 0,
                  let address = interface.pointee.ifa_addr,
                  address.pointee.sa_family == UInt8(AF_INET) else { continue }
            var host = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { pointer in
                var ipv4 = pointer.pointee.sin_addr
                host.withUnsafeMutableBufferPointer { buffer in
                    _ = inet_ntop(AF_INET, &ipv4, buffer.baseAddress, socklen_t(buffer.count))
                }
            }
            let value = String(cString: host)
            if !value.isEmpty, !value.hasPrefix("169.254.") { return value }
        }
        return nil
    }
}

private enum MCPError: LocalizedError {
    case message(String)

    var errorDescription: String? {
        switch self {
        case .message(let value): return value
        }
    }
}
