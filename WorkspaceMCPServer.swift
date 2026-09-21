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

    private let tokenDefaultsKey = "workspace.mcp.accessToken.v1"
    private var listener: NWListener?
    private var rootDirectory: URL?
    private let fileManager = FileManager.default

    private init() {
        let stored = UserDefaults.standard.string(forKey: tokenDefaultsKey)
        accessToken = stored ?? Self.makeToken()
        if stored == nil {
            UserDefaults.standard.set(accessToken, forKey: tokenDefaultsKey)
        }
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
        let path = rawPath.split(separator: "?", maxSplits: 1).first.map(String.init) ?? rawPath

        if path == "/health" && method == "GET" {
            return httpResponse(body: json([
                "name": "Workspace MCP Bridge",
                "status": "ok",
                "tools": ["list_files", "read_file", "copy_file", "move_file", "delete_file", "make_directory"]
            ]))
        }

        guard headers["authorization"] == "Bearer \(accessToken)" else {
            return httpResponse(status: "401 Unauthorized", body: json(["error": "Bearer token required"]))
        }

        if path == "/tools" && method == "GET" {
            return httpResponse(body: json([
                "tools": [
                    ["name": "list_files", "arguments": ["path"]],
                    ["name": "read_file", "arguments": ["path"]],
                    ["name": "copy_file", "arguments": ["source", "destination"]],
                    ["name": "move_file", "arguments": ["source", "destination"]],
                    ["name": "delete_file", "arguments": ["path"]],
                    ["name": "make_directory", "arguments": ["path"]]
                ]
            ]))
        }

        guard path == "/call", method == "POST",
              let bodyData = bodyText.data(using: .utf8),
              let payload = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any],
              let tool = payload["tool"] as? String else {
            return httpResponse(status: "404 Not Found", body: json(["error": "Use GET /tools or POST /call"]))
        }

        let arguments = payload["arguments"] as? [String: Any] ?? [:]
        return toolResponse(tool: tool, arguments: arguments)
    }

    private func toolResponse(tool: String, arguments: [String: Any]) -> Data {
        do {
            switch tool {
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
            return httpResponse(status: "400 Bad Request", body: json(["error": error.localizedDescription]))
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
