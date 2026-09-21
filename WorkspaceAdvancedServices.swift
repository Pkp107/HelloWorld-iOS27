import Combine
import Foundation
import Network
import SwiftUI
import UIKit

// MARK: - Advanced services coordinator

/// The advanced services are intentionally kept separate from the core shell.
/// Each surface can be routed into its own Workspace app without coupling the
/// UI to a particular remote provider or runtime installation.
struct WorkspaceAdvancedServicesView: View {
    @ObservedObject var store: WorkspaceStore
    @State private var selection: WorkspaceAdvancedServiceTab = .server

    var body: some View {
        TabView(selection: $selection) {
            WorkspaceLocalhostServerView()
                .tabItem { Label("Server", systemImage: "server.rack") }
                .tag(WorkspaceAdvancedServiceTab.server)
            WorkspacePiSSHView()
                .tabItem { Label("Pi / SSH", systemImage: "terminal.fill") }
                .tag(WorkspaceAdvancedServiceTab.pi)
            WorkspaceLocalAIView()
                .tabItem { Label("Local AI", systemImage: "sparkles") }
                .tag(WorkspaceAdvancedServiceTab.ai)
            WorkspaceGitHubAdvancedView()
                .tabItem { Label("GitHub", systemImage: "arrow.triangle.branch") }
                .tag(WorkspaceAdvancedServiceTab.github)
            WorkspaceModuleInstallView()
                .tabItem { Label("Modules", systemImage: "shippingbox.fill") }
                .tag(WorkspaceAdvancedServiceTab.modules)
            WorkspaceFridaMCPTerminalView()
                .tabItem { Label("Guest terminal", systemImage: "rectangle.split.2x1") }
                .tag(WorkspaceAdvancedServiceTab.frida)
        }
        .tint(.indigo)
    }
}

enum WorkspaceAdvancedServiceTab: Hashable {
    case server, pi, ai, github, modules, frida
}

// MARK: - Localhost project server

@MainActor
final class WorkspaceLocalhostServerModel: ObservableObject {
    @Published private(set) var running = false
    @Published private(set) var endpoint: URL?
    @Published private(set) var requestCount = 0
    @Published var status = "Stopped"
    @Published var advertiseOnLAN = false
    @Published var projectName = "Workspace project"

    private var listener: NWListener?

    func toggle() {
        running ? stop() : start()
    }

    func start() {
        stop()
        do {
            let listener = try NWListener(using: .tcp, on: .any)
            if !advertiseOnLAN {
                listener.parameters.requiredLocalEndpoint = .hostPort(
                    host: NWEndpoint.Host("127.0.0.1"), port: .any
                )
            }
            listener.stateUpdateHandler = { [weak self, weak listener] state in
                Task { @MainActor in
                    guard let self else { return }
                    switch state {
                    case .ready:
                        let port = listener?.port?.rawValue ?? 0
                        let host = self.advertiseOnLAN ? "0.0.0.0" : "127.0.0.1"
                        self.endpoint = URL(string: "http://\(host):\(port)")
                        self.running = true
                        self.status = "Listening on \(host):\(port)"
                    case .failed(let error):
                        self.status = "Server failed: \(error.localizedDescription)"
                        self.stop()
                    case .cancelled:
                        self.running = false
                    default:
                        break
                    }
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                connection.stateUpdateHandler = { [weak self, weak connection] state in
                    guard case .ready = state else { return }
                    Task { @MainActor in
                        guard let connection else { return }
                        self?.serve(connection)
                    }
                }
                connection.start(queue: .global(qos: .userInitiated))
            }
            self.listener = listener
            listener.start(queue: .global(qos: .userInitiated))
            status = "Starting server..."
        } catch {
            status = "Could not start server: \(error.localizedDescription)"
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        running = false
        endpoint = nil
        status = "Stopped"
    }

    private func serve(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 32_768) { [weak self] data, _, _, _ in
            guard let self else { connection.cancel(); return }
            Task { @MainActor in
                self.requestCount += 1
                let body = "{\"project\":\"\(self.projectName.replacingOccurrences(of: "\"", with: "'"))\",\"status\":\"ready\"}"
                let response = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
                connection.send(content: response.data(using: .utf8), completion: .contentProcessed { _ in connection.cancel() })
            }
        }
    }
}

struct WorkspaceLocalhostServerView: View {
    @StateObject private var model = WorkspaceLocalhostServerModel()

    var body: some View {
        NavigationStack {
            Form {
                Section("Project server") {
                    TextField("Project name", text: $model.projectName)
                    Toggle("Advertise on local network", isOn: $model.advertiseOnLAN)
                    LabeledContent("Status", value: model.status)
                    LabeledContent("Requests", value: "\(model.requestCount)")
                    if let endpoint = model.endpoint {
                        Text(endpoint.absoluteString)
                            .font(.footnote.monospaced())
                            .textSelection(.enabled)
                    }
                    Button(model.running ? "Stop server" : "Start server") { model.toggle() }
                }
                Section {
                    Label("This is a small health endpoint for development workflows. Host user projects through a dedicated runtime or Raspberry Pi when they need file watching, WebSockets, or long-running processes.", systemImage: "info.circle")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Localhost")
        }
    }
}

// MARK: - Raspberry Pi / SSH configuration

struct WorkspacePiSSHConfiguration: Codable, Equatable {
    var host = ""
    var port = "22"
    var username = ""
    var keyPath = ""
    var workspacePath = "~/Workspace"
    var useTLSHealthCheck = false
}

@MainActor
final class WorkspacePiSSHModel: ObservableObject {
    @Published var configuration: WorkspacePiSSHConfiguration
    @Published private(set) var status = "Not tested"

    private let defaultsKey = "workspace.piSSH.configuration.v1"

    init() {
        if let data = UserDefaults.standard.data(forKey: defaultsKey),
           let value = try? JSONDecoder().decode(WorkspacePiSSHConfiguration.self, from: data) {
            configuration = value
        } else {
            configuration = WorkspacePiSSHConfiguration()
        }
    }

    func save() {
        if let data = try? JSONEncoder().encode(configuration) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
        status = "Configuration saved"
    }

    func testConnection() {
        guard !configuration.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            status = "Enter a host first"
            return
        }
        save()
        status = "SSH client integration is ready for \(configuration.username.isEmpty ? "the configured user" : configuration.username)@\(configuration.host):\(configuration.port)."
    }
}

struct WorkspacePiSSHView: View {
    @StateObject private var model = WorkspacePiSSHModel()

    var body: some View {
        NavigationStack {
            Form {
                Section("Remote host") {
                    TextField("Host or IP address", text: $model.configuration.host)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("Port", text: $model.configuration.port)
                        .keyboardType(.numberPad)
                    TextField("Username", text: $model.configuration.username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("Private key path", text: $model.configuration.keyPath)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("Remote workspace path", text: $model.configuration.workspacePath)
                }
                Section("Actions") {
                    Button("Save configuration") { model.save() }
                    Button("Test SSH configuration") { model.testConnection() }
                    Text(model.status).font(.footnote).foregroundStyle(.secondary)
                }
                Section {
                    Label("Swift Foundation does not include an SSH client. This screen stores the connection and is ready for a bundled SSH transport or a Raspberry Pi job runner.", systemImage: "lock.shield")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Pi / SSH")
        }
    }
}

// MARK: - Local AI model registry

struct WorkspaceAIModelDescriptor: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String
    var provider: String
    var size: String
    var downloaded: Bool
    var supportsCode: Bool

    init(id: UUID = UUID(), name: String, provider: String, size: String, downloaded: Bool = false, supportsCode: Bool = true) {
        self.id = id
        self.name = name
        self.provider = provider
        self.size = size
        self.downloaded = downloaded
        self.supportsCode = supportsCode
    }
}

@MainActor
final class WorkspaceLocalAIModel: ObservableObject {
    @Published var models: [WorkspaceAIModelDescriptor]
    @Published var selectedModelID: UUID?
    @Published private(set) var status = "No model is running"

    private let defaultsKey = "workspace.localAI.models.v1"
    private let selectionKey = "workspace.localAI.selectedModel.v1"

    init() {
        if let data = UserDefaults.standard.data(forKey: defaultsKey),
           let values = try? JSONDecoder().decode([WorkspaceAIModelDescriptor].self, from: data) {
            models = values
        } else {
            models = [
                WorkspaceAIModelDescriptor(name: "SmolLM Code", provider: "Hugging Face", size: "~1 GB"),
                WorkspaceAIModelDescriptor(name: "Phi-3 Mini", provider: "Microsoft", size: "~2.4 GB"),
                WorkspaceAIModelDescriptor(name: "Pi Code Runner", provider: "Raspberry Pi", size: "Remote", downloaded: true)
            ]
        }
        selectedModelID = UserDefaults.standard.string(forKey: selectionKey).flatMap(UUID.init(uuidString:))
    }

    func toggle(_ model: WorkspaceAIModelDescriptor) {
        guard let index = models.firstIndex(where: { $0.id == model.id }) else { return }
        models[index].downloaded.toggle()
        if models[index].downloaded { status = "\(models[index].name) is available to a future inference runtime." }
        persist()
    }

    func select(_ model: WorkspaceAIModelDescriptor) {
        selectedModelID = model.id
        UserDefaults.standard.set(model.id.uuidString, forKey: selectionKey)
        status = model.downloaded ? "Selected \(model.name)" : "Download \(model.name) before running it"
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(models) { UserDefaults.standard.set(data, forKey: defaultsKey) }
    }
}

struct WorkspaceLocalAIView: View {
    @StateObject private var model = WorkspaceLocalAIModel()

    var body: some View {
        NavigationStack {
            List {
                Section("Models") {
                    ForEach(model.models) { item in
                        HStack(spacing: 12) {
                            Image(systemName: item.downloaded ? "checkmark.circle.fill" : "arrow.down.circle")
                                .foregroundStyle(item.downloaded ? .green : .secondary)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(item.name).font(.headline)
                                Text("\(item.provider) · \(item.size)").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button(item.downloaded ? "Remove" : "Add") { model.toggle(item) }
                                .buttonStyle(.borderless)
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { model.select(item) }
                    }
                }
                Section {
                    Text(model.status).font(.footnote).foregroundStyle(.secondary)
                    Label("Model files are optional and are not bundled with the app. A compatible inference runtime or remote Pi service is still required.", systemImage: "info.circle")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Local AI")
        }
    }
}

// MARK: - GitHub artifacts / PRs / issues / releases

struct WorkspaceGitHubAdvancedItem: Identifiable, Hashable {
    let id: String
    let title: String
    let subtitle: String
    let url: URL?
}

@MainActor
final class WorkspaceGitHubAdvancedModel: ObservableObject {
    @Published var token = ""
    @Published var repository = ""
    @Published private(set) var items: [WorkspaceGitHubAdvancedItem] = []
    @Published private(set) var section = ""
    @Published private(set) var status = "Enter owner/repository and a token with read access."
    @Published private(set) var isLoading = false

    private let decoder = JSONDecoder()

    func load(_ section: String) {
        let path: String
        switch section {
        case "Pull requests": path = "pulls?state=all&per_page=50"
        case "Issues": path = "issues?state=all&per_page=50"
        case "Releases": path = "releases?per_page=50"
        default: path = "actions/artifacts?per_page=50"
        }
        let repo = repository.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !repo.isEmpty, !token.isEmpty,
              let url = URL(string: "https://api.github.com/repos/\(repo)/\(path)") else {
            status = "Enter a repository and token first."
            return
        }
        isLoading = true
        self.section = section
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            Task { @MainActor in
                guard let self else { return }
                self.isLoading = false
                if let error { self.status = error.localizedDescription; return }
                guard let data, let http = response as? HTTPURLResponse else { self.status = "GitHub returned no response."; return }
                guard (200..<300).contains(http.statusCode) else {
                    self.status = "GitHub returned HTTP \(http.statusCode). Check the repository and token scope."
                    return
                }
                self.items = Self.decodeItems(data: data, section: section, decoder: self.decoder)
                self.status = "Loaded \(self.items.count) \(section.lowercased())."
            }
        }.resume()
    }

    private static func decodeItems(data: Data, section: String, decoder: JSONDecoder) -> [WorkspaceGitHubAdvancedItem] {
        guard let document = try? JSONSerialization.jsonObject(with: data) else { return [] }
        let values: [[String: Any]]
        if let array = document as? [[String: Any]] {
            values = array
        } else if let dictionary = document as? [String: Any], let artifacts = dictionary["artifacts"] as? [[String: Any]] {
            values = artifacts
        } else {
            return []
        }
        return values.compactMap { value in
            guard let id = value["id"] else { return nil }
            let title = (value["name"] as? String) ?? (value["title"] as? String) ?? "Untitled"
            let number = value["number"].map { "#\($0)" } ?? ""
            let owner = (value["login"] as? String) ?? ""
            let html = (value["html_url"] as? String).flatMap { URL(string: $0) }
            let subtitle = [number, owner, section == "Artifacts" ? "Artifact" : ""].filter { !$0.isEmpty }.joined(separator: " · ")
            return WorkspaceGitHubAdvancedItem(id: "\(id)", title: title, subtitle: subtitle, url: html)
        }
    }
}

struct WorkspaceGitHubAdvancedView: View {
    @StateObject private var model = WorkspaceGitHubAdvancedModel()
    private let sections = ["Artifacts", "Pull requests", "Issues", "Releases"]

    var body: some View {
        NavigationStack {
            List {
                Section("Connection") {
                    TextField("owner/repository", text: $model.repository)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("GitHub token", text: $model.token)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack {
                            ForEach(sections, id: \.self) { value in
                                Button(value) { model.load(value) }
                                    .buttonStyle(.bordered)
                            }
                        }
                    }
                }
                Section(model.section.isEmpty ? "Results" : model.section) {
                    if model.isLoading { ProgressView() }
                    ForEach(model.items) { item in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.title)
                            if !item.subtitle.isEmpty { Text(item.subtitle).font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                    if model.items.isEmpty && !model.isLoading { Text(model.status).font(.footnote).foregroundStyle(.secondary) }
                }
            }
            .navigationTitle("GitHub details")
        }
    }
}

// MARK: - Optional module download/install status

struct WorkspaceModuleInstallRecord: Identifiable, Codable, Hashable {
    let id: String
    var state: String
    var progress: Double
    var note: String
}

@MainActor
final class WorkspaceModuleInstallModel: ObservableObject {
    @Published var records: [WorkspaceModuleInstallRecord]
    private let defaultsKey = "workspace.moduleInstallRecords.v1"

    init() {
        if let data = UserDefaults.standard.data(forKey: defaultsKey),
           let values = try? JSONDecoder().decode([WorkspaceModuleInstallRecord].self, from: data) {
            records = values
        } else {
            records = []
        }
    }

    func install(_ module: WorkspaceModuleID) {
        if let index = records.firstIndex(where: { $0.id == module.rawValue }) {
            records[index].state = "Queued"
            records[index].note = "Waiting for the module runtime package."
        } else {
            records.append(WorkspaceModuleInstallRecord(id: module.rawValue, state: "Queued", progress: 0, note: "Waiting for the module runtime package."))
        }
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(records) { UserDefaults.standard.set(data, forKey: defaultsKey) }
    }
}

struct WorkspaceModuleInstallView: View {
    @StateObject private var model = WorkspaceModuleInstallModel()

    var body: some View {
        NavigationStack {
            List {
                ForEach(WorkspaceModuleID.allCases) { module in
                    let record = model.records.first(where: { $0.id == module.rawValue })
                    HStack {
                        Image(systemName: module.symbol)
                            .frame(width: 26)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(module.title)
                            Text(record?.note ?? "\(module.storageEstimate) · \(module.executionNote)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(record == nil ? "Install" : (record?.state ?? "Queued")) { model.install(module) }
                            .buttonStyle(.borderless)
                    }
                }
            }
            .navigationTitle("Module packages")
            .safeAreaInset(edge: .bottom) {
                Text("Module downloads are staged here. Runtime binaries must come from a compatible signed package or remote builder.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                    .background(.bar)
            }
        }
    }
}

// MARK: - LiveContainer Frida guest terminal and MCP bridge

struct WorkspaceFridaMCPConfiguration: Codable, Equatable {
    var endpoint = "http://127.0.0.1:27042"
    var token = ""
}

@MainActor
final class WorkspaceFridaMCPModel: ObservableObject {
    @Published var configuration: WorkspaceFridaMCPConfiguration
    @Published var code = "console.log('hello from Workspace')"
    @Published private(set) var logs: [String] = []
    @Published private(set) var status = "Guest endpoint not connected"
    @Published private(set) var isLoading = false

    private let defaultsKey = "workspace.fridaMCP.configuration.v1"

    init() {
        if let data = UserDefaults.standard.data(forKey: defaultsKey),
           let value = try? JSONDecoder().decode(WorkspaceFridaMCPConfiguration.self, from: data) {
            configuration = value
        } else {
            configuration = WorkspaceFridaMCPConfiguration()
        }
    }

    func fetchLogs() {
        request(path: "/logs", method: "GET", body: nil) { [weak self] data in
            let text = String(data: data, encoding: .utf8) ?? "(empty response)"
            self?.logs = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        }
    }

    func executeCode() {
        guard !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { status = "Enter code first"; return }
        let body = try? JSONSerialization.data(withJSONObject: ["code": code])
        request(path: "/eval", method: "POST", body: body) { [weak self] data in
            let text = String(data: data, encoding: .utf8) ?? "(empty response)"
            self?.logs.append("eval: \(text)")
        }
    }

    private func request(path: String, method: String, body: Data?, completion: @escaping (Data) -> Void) {
        let endpoint = configuration.endpoint.hasSuffix("/") ? configuration.endpoint : configuration.endpoint + "/"
        let relativePath = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let base = URL(string: endpoint), let url = URL(string: relativePath, relativeTo: base) else { status = "Invalid guest endpoint"; return }
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { status = "Guest endpoint must use HTTP or HTTPS"; return }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !configuration.token.isEmpty { request.setValue("Bearer \(configuration.token)", forHTTPHeaderField: "Authorization") }
        isLoading = true
        status = "Connecting to guest MCP..."
        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            Task { @MainActor in
                guard let self else { return }
                self.isLoading = false
                if let error { self.status = error.localizedDescription; return }
                guard let data, let http = response as? HTTPURLResponse else { self.status = "Guest MCP returned no response"; return }
                guard (200..<300).contains(http.statusCode) else { self.status = "Guest MCP returned HTTP \(http.statusCode)"; return }
                self.status = "Connected to LiveContainer guest MCP"
                completion(data)
            }
        }.resume()
    }
}

struct WorkspaceFridaMCPTerminalView: View {
    @StateObject private var model = WorkspaceFridaMCPModel()

    var body: some View {
        NavigationStack {
            GeometryReader { proxy in
                if proxy.size.width > proxy.size.height {
                    HStack(spacing: 0) { guestPanel; terminalPanel }
                } else {
                    VStack(spacing: 0) { guestPanel; terminalPanel }
                }
            }
            .navigationTitle("Guest terminal")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Logs") { model.fetchLogs() }
                }
            }
        }
    }

    private var guestPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("LiveContainer guest", systemImage: "shippingbox.fill").font(.headline)
            Text("Run this alongside a supported guest app. The guest must expose a Frida Gadget MCP endpoint; Workspace cannot attach to arbitrary iOS processes.")
                .font(.footnote).foregroundStyle(.secondary)
            TextField("Guest MCP URL", text: $model.configuration.endpoint)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
            SecureField("Bearer token (optional)", text: $model.configuration.token)
            Text(model.status).font(.caption).foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.thinMaterial)
    }

    private var terminalPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Terminal / logs").font(.headline)
            TextEditor(text: $model.code)
                .font(.system(.footnote, design: .monospaced))
                .frame(minHeight: 90)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary))
            HStack {
                Button("Execute") { model.executeCode() }.buttonStyle(.borderedProminent)
                Button("Refresh logs") { model.fetchLogs() }.buttonStyle(.bordered)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(model.logs.enumerated()), id: \.offset) { _, line in
                        Text(line).font(.system(.caption2, design: .monospaced)).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

// MARK: - Native guest split overlay

struct WorkspaceGuestLogEntry: Identifiable, Codable, Hashable {
    let id: UUID
    let date: Date
    let level: String
    let message: String
}

struct WorkspaceGuestEvaluation: Identifiable, Codable, Hashable {
    let id: UUID
    let createdAt: Date
    let code: String
    var result: String?
    var error: String?
}

@MainActor
final class WorkspaceGuestSessionStore: ObservableObject {
    static let shared = WorkspaceGuestSessionStore()

    @Published private(set) var appName: String?
    @Published private(set) var bundleIdentifier: String?
    @Published private(set) var isActive = false
    @Published private(set) var logs: [WorkspaceGuestLogEntry] = []
    @Published private(set) var evaluations: [WorkspaceGuestEvaluation] = []

    private init() {}

    func start(appName: String, bundleIdentifier: String) {
        if isActive, self.appName == appName, self.bundleIdentifier == bundleIdentifier {
            return
        }
        self.appName = appName
        self.bundleIdentifier = bundleIdentifier
        isActive = true
        logs = []
        evaluations = []
        appendLog("Started guest session for \(appName).", level: "system")
    }

    func stop(reason: String? = nil) {
        if let reason, !reason.isEmpty { appendLog(reason, level: "error") }
        isActive = false
    }

    func appendLog(_ message: String, level: String = "info") {
        let cleaned = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }
        logs.append(WorkspaceGuestLogEntry(id: UUID(), date: .now, level: level, message: cleaned))
        if logs.count > 500 { logs.removeFirst(logs.count - 500) }
    }

    @discardableResult
    func submitEvaluation(_ code: String) -> UUID {
        let evaluation = WorkspaceGuestEvaluation(id: UUID(), createdAt: .now, code: code, result: nil, error: nil)
        evaluations.append(evaluation)
        appendLog("Queued Frida evaluation \(evaluation.id.uuidString.prefix(8)).", level: "eval")
        return evaluation.id
    }

    func completeEvaluation(id: UUID, result: String? = nil, error: String? = nil) {
        guard let index = evaluations.firstIndex(where: { $0.id == id }) else { return }
        evaluations[index].result = result
        evaluations[index].error = error
        if let error { appendLog("Evaluation failed: \(error)", level: "error") }
        else if let result { appendLog(result, level: "result") }
    }

    func snapshot() -> [String: Any] {
        [
            "active": isActive,
            "app": appName ?? "",
            "bundleIdentifier": bundleIdentifier ?? "",
            "logCount": logs.count,
            "pendingEvaluations": evaluations.filter { $0.result == nil && $0.error == nil }.count
        ]
    }
}

@MainActor
final class WorkspaceGuestSplitOverlayController {
    static let shared = WorkspaceGuestSplitOverlayController()
    private var window: UIWindow?

    func show(appName: String, bundleIdentifier: String) {
        guard window == nil else { return }
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }) else {
            WorkspaceGuestSessionStore.shared.stop(reason: "The Workspace scene is not active.")
            return
        }
        // The launcher starts the session before LiveContainer runs the guest.
        // Keep that session so startup logs are not discarded when the overlay
        // is created; initialize it here only for standalone callers.
        if !WorkspaceGuestSessionStore.shared.isActive {
            WorkspaceGuestSessionStore.shared.start(appName: appName, bundleIdentifier: bundleIdentifier)
        }

        let overlay = UIWindow(windowScene: scene)
        overlay.backgroundColor = .clear
        overlay.windowLevel = UIWindow.Level(rawValue: UIWindow.Level.statusBar.rawValue + 1)
        let host = UIHostingController(rootView: WorkspaceGuestSplitOverlayView { [weak self] in
            self?.hide()
        })
        host.view.backgroundColor = .clear
        overlay.rootViewController = host
        overlay.isHidden = false
        window = overlay
    }

    func hide() {
        window?.isHidden = true
        window = nil
        WorkspaceGuestSessionStore.shared.stop()
    }
}

private struct WorkspaceGuestSplitOverlayView: View {
    @ObservedObject private var session = WorkspaceGuestSessionStore.shared
    @StateObject private var terminal = WorkspaceFridaMCPModel()
    let onHome: () -> Void

    var body: some View {
        GeometryReader { proxy in
            let landscape = proxy.size.width > proxy.size.height
            ZStack {
                Color.clear.allowsHitTesting(false)
                terminalPanel
                    .frame(
                        width: landscape ? proxy.size.width * 0.46 : proxy.size.width,
                        height: landscape ? proxy.size.height : proxy.size.height * 0.46
                    )
                    .background(.ultraThinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .padding(8)
                    .frame(
                        maxWidth: .infinity,
                        maxHeight: .infinity,
                        alignment: landscape ? .trailing : .bottom
                    )

                Button(action: onHome) {
                    Capsule().fill(.primary.opacity(0.8)).frame(width: 6, height: 92)
                }
                .frame(width: 44, height: 120)
                .contentShape(Rectangle())
                .buttonStyle(.plain)
                .accessibilityLabel("Return to Workspace home")
                .frame(
                    maxWidth: .infinity,
                    maxHeight: .infinity,
                    alignment: landscape ? .leading : .trailing
                )
                .padding(landscape ? .leading : .trailing, 6)
            }
        }
        .ignoresSafeArea()
    }

    private var terminalPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(session.appName ?? "LiveContainer guest", systemImage: "ant.fill")
                    .font(.headline)
                Spacer()
                Button { terminal.fetchLogs() } label: { Image(systemName: "arrow.clockwise") }
                    .accessibilityLabel("Refresh guest logs")
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 5) {
                    ForEach(session.logs) { entry in
                        Text("[\(entry.level)] \(entry.message)")
                            .font(.caption.monospaced())
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    ForEach(terminal.logs, id: \.self) { line in
                        Text(line)
                            .font(.caption.monospaced())
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .frame(maxHeight: .infinity)
            TextField("Frida JavaScript", text: $terminal.code, axis: .vertical)
                .font(.caption.monospaced())
                .textFieldStyle(.roundedBorder)
            HStack {
                Text(terminal.status)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Spacer()
                Button("Execute") { terminal.executeCode() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(12)
        .onAppear {
            let root = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Workspace Files", isDirectory: true)
            if !WorkspaceMCPServer.shared.isRunning {
                WorkspaceMCPServer.shared.start(rootDirectory: root, advertiseOnLAN: false)
            }
            configureGuestBridge()
        }
    }

    private func configureGuestBridge() {
        // NWListener publishes its endpoint asynchronously. Wait for that
        // state transition before making the first request, otherwise the
        // client would fall back to the unrelated default Frida port.
        Task { @MainActor in
            for _ in 0..<20 {
                if let endpoint = WorkspaceMCPServer.shared.endpoint {
                    var base = endpoint.absoluteString
                    if !base.hasSuffix("/") { base += "/" }
                    terminal.configuration.endpoint = base + "guest/"
                    terminal.configuration.token = WorkspaceMCPServer.shared.accessToken
                    terminal.fetchLogs()
                    return
                }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
        }
    }
}
