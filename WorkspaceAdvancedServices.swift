import Combine
import Foundation
import Network
import SwiftUI
import UIKit
import UniformTypeIdentifiers

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
            WorkspaceGitHubAdvancedView()
                .tabItem { Label("GitHub", systemImage: "arrow.triangle.branch") }
                .tag(WorkspaceAdvancedServiceTab.github)
            WorkspaceFridaMCPTerminalView()
                .tabItem { Label("Guest terminal", systemImage: "rectangle.split.2x1") }
                .tag(WorkspaceAdvancedServiceTab.frida)
        }
        .tint(.indigo)
    }
}

enum WorkspaceAdvancedServiceTab: Hashable {
    case server, pi, github, frida
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

// MARK: - Workspace AI app

/// A model entry describes the local file the user imported. Workspace does not
/// mark a model as ready until a model file is present in its private Models
/// directory, and it never pretends that a missing inference runtime is active.
struct WorkspaceAIModelDescriptor: Identifiable, Codable, Hashable {
    let id: String
    let name: String
    let provider: String
    let size: String
    let summary: String
    var modelFileName: String?

    var isInstalled: Bool { modelFileName != nil }
}

struct WorkspaceAIChatMessage: Identifiable, Codable, Hashable {
    enum Role: String, Codable { case user, assistant }
    let id: UUID
    let role: Role
    let text: String
    let createdAt: Date
}

@MainActor
final class WorkspaceAIChatModel: ObservableObject {
    @Published var models: [WorkspaceAIModelDescriptor]
    @Published var selectedModelID: String
    @Published var messages: [WorkspaceAIChatMessage]
    @Published var draft = ""
    @Published private(set) var status = "Choose a model to begin"
    @Published private(set) var isSending = false

    private let defaultsKey = "workspace.ai.chat.v2"
    private let modelDirectory: URL
    private let fileManager = FileManager.default

    init(store: WorkspaceStore) {
        // Shared Workspace Files is also writable by the share extension.
        // Model imports therefore do not depend on UIDocumentPicker.
        modelDirectory = store.workspaceFolderDirectory(named: "AI Models")
        try? fileManager.createDirectory(at: modelDirectory, withIntermediateDirectories: true)

        if let data = UserDefaults.standard.data(forKey: defaultsKey),
           let saved = try? JSONDecoder().decode(Persisted.self, from: data) {
            models = Self.reconcile(saved.models, modelDirectory: modelDirectory)
            selectedModelID = saved.selectedModelID
            messages = saved.messages
        } else {
            models = Self.defaultModels
            selectedModelID = Self.defaultModels[0].id
            messages = []
        }
        normalizeSelection()
        persist()
    }

    var selectedModel: WorkspaceAIModelDescriptor? {
        models.first { $0.id == selectedModelID }
    }

    var hasInstalledModel: Bool { models.contains(where: { $0.isInstalled }) }

    /// Returns model files that were copied into Workspace Files or shared to
    /// the app's group inbox. This is the reliable path on devices where the
    /// Files provider picker does not return a usable security-scoped URL.
    func workspaceModelFiles() -> [URL] {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        var roots: [URL] = [
            documents.appendingPathComponent("Workspace Files/AI Models", isDirectory: true),
            documents.appendingPathComponent("Workspace Files/Incoming", isDirectory: true)
        ]
#if LIVE_CONTAINER_NATIVE
        if let shared = LCSharedUtils.appGroupPath() {
            roots.append(shared.appendingPathComponent("Workspace-iOS27/Workspace Files/AI Models", isDirectory: true))
            // Read the old inbox path as a migration aid for models shared by
            // an earlier build.
            roots.append(shared.appendingPathComponent("Workspace-iOS27/AI Models/Incoming", isDirectory: true))
        }
#endif
        let allowed = Set(["gguf", "ggml", "safetensors", "mlmodel", "mlmodelc", "mlpackage", "onnx", "bin", "model"])
        var results: [URL] = []
        for root in roots {
            guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey], options: [.skipsHiddenFiles]) else { continue }
            for case let url as URL in enumerator {
                let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
                // Core ML packages are directories; all other supported model
                // formats are regular files.
                let ext = url.pathExtension.lowercased()
                guard allowed.contains(ext), !isDirectory || ext == "mlpackage" || ext == "mlmodelc" else { continue }
                results.append(url)
            }
        }
        return results.reduce(into: [String: URL]()) { $0[$1.standardizedFileURL.path] = $1 }
            .values
            .sorted { $0.path.localizedCaseInsensitiveCompare($1.path) == .orderedAscending }
    }

    func select(_ model: WorkspaceAIModelDescriptor) {
        selectedModelID = model.id
        status = model.isInstalled
            ? "\(model.name) is selected"
            : "Import a \(model.name) model file to use it"
        persist()
    }

    func importModel(from sourceURL: URL) -> Bool {
        let hasAccess = sourceURL.startAccessingSecurityScopedResource()
        defer { if hasAccess { sourceURL.stopAccessingSecurityScopedResource() } }
        guard let model = selectedModel else {
            status = "Choose a model first"
            return false
        }
        do {
            let ext = sourceURL.pathExtension.isEmpty ? "bin" : sourceURL.pathExtension
            let destination = modelDirectory.appendingPathComponent("\(model.id).\(ext)", isDirectory: false)
            if sourceURL.standardizedFileURL != destination.standardizedFileURL,
               fileManager.fileExists(atPath: destination.path) {
                try fileManager.removeItem(at: destination)
            }
            if sourceURL.standardizedFileURL != destination.standardizedFileURL {
                try fileManager.copyItem(at: sourceURL, to: destination)
            }
            guard let index = models.firstIndex(where: { $0.id == model.id }) else { return false }
            models[index].modelFileName = destination.lastPathComponent
            status = "\(model.name) is ready in Workspace Files / AI Models."
            persist()
            return true
        } catch {
            status = "Could not import model: \(error.localizedDescription)"
            return false
        }
    }

    func importWorkspaceModel(from sourceURL: URL) -> Bool {
        importModel(from: sourceURL)
    }

    func remove(_ model: WorkspaceAIModelDescriptor) {
        if let fileName = model.modelFileName {
            try? FileManager.default.removeItem(at: modelDirectory.appendingPathComponent(fileName, isDirectory: false))
        }
        guard let index = models.firstIndex(where: { $0.id == model.id }) else { return }
        models[index].modelFileName = nil
        status = "\(model.name) removed"
        persist()
    }

    func send() {
        let prompt = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty, !isSending else { return }
        guard let model = selectedModel else {
            status = "Choose a model first"
            return
        }
        guard model.isInstalled else {
            status = "Import a \(model.name) model file first"
            return
        }

        messages.append(WorkspaceAIChatMessage(id: UUID(), role: .user, text: prompt, createdAt: .now))
        draft = ""
        isSending = true
        status = "Preparing \(model.name)…"
        persist()

        // The UI is ready for an embedded llama.cpp/MLX bridge. Do not return
        // fabricated model output while no inference engine is linked.
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(220))
            let reply = "\(model.name) is installed, but this build has no embedded inference runtime yet. Add a compatible on-device backend to generate a response from the model file."
            messages.append(WorkspaceAIChatMessage(id: UUID(), role: .assistant, text: reply, createdAt: .now))
            isSending = false
            status = "Model ready; inference runtime unavailable"
            persist()
        }
    }

    func clearChat() {
        messages.removeAll()
        status = selectedModel.map { $0.isInstalled ? "Ready to chat with \($0.name)" : "Import a \($0.name) model file to use it" } ?? "Choose a model to begin"
        persist()
    }

    private func normalizeSelection() {
        if !models.contains(where: { $0.id == selectedModelID }) {
            selectedModelID = models.first?.id ?? "qwen35-4b"
        }
    }

    private func persist() {
        let value = Persisted(models: models, selectedModelID: selectedModelID, messages: messages)
        if let data = try? JSONEncoder().encode(value) { UserDefaults.standard.set(data, forKey: defaultsKey) }
    }

    private struct Persisted: Codable {
        var models: [WorkspaceAIModelDescriptor]
        var selectedModelID: String
        var messages: [WorkspaceAIChatMessage]
    }

    private static let defaultModels: [WorkspaceAIModelDescriptor] = [
        WorkspaceAIModelDescriptor(id: "qwen35-4b", name: "Qwen 3.5 4B", provider: "Qwen", size: "~2.5 GB", summary: "General chat and coding model", modelFileName: nil),
        WorkspaceAIModelDescriptor(id: "phi4-mini", name: "Phi-4 Mini", provider: "Microsoft", size: "~2.5 GB", summary: "Compact reasoning and code model", modelFileName: nil),
        WorkspaceAIModelDescriptor(id: "llama32-3b", name: "Llama 3.2 3B", provider: "Meta", size: "~2 GB", summary: "General-purpose local assistant", modelFileName: nil)
    ]

    private static func reconcile(_ saved: [WorkspaceAIModelDescriptor], modelDirectory: URL) -> [WorkspaceAIModelDescriptor] {
        defaultModels.map { base in
            guard let old = saved.first(where: { $0.id == base.id }),
                  let fileName = old.modelFileName,
                  FileManager.default.fileExists(atPath: modelDirectory.appendingPathComponent(fileName).path) else { return base }
            var value = base
            value.modelFileName = fileName
            return value
        }
    }
}

struct WorkspaceAIChatView: View {
    @ObservedObject var store: WorkspaceStore
    @StateObject private var model: WorkspaceAIChatModel
    @State private var showingModelSheet = false

    init(store: WorkspaceStore) {
        _store = ObservedObject(wrappedValue: store)
        _model = StateObject(wrappedValue: WorkspaceAIChatModel(store: store))
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if model.messages.isEmpty {
                    emptyState
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 12) {
                                ForEach(model.messages) { message in
                                    WorkspaceAIMessageBubble(message: message)
                                        .id(message.id)
                                }
                            }
                            .padding(16)
                        }
                        .onChange(of: model.messages.count) { _, _ in
                            if let last = model.messages.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } }
                        }
                    }
                }

                Divider()
                HStack(alignment: .bottom, spacing: 10) {
                    TextField("Ask your local model…", text: $model.draft, axis: .vertical)
                        .lineLimit(1...5)
                        .textFieldStyle(.roundedBorder)
                    Button { model.send() } label: {
                        Image(systemName: model.isSending ? "hourglass" : "arrow.up.circle.fill")
                            .font(.title2)
                    }
                    .disabled(model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.isSending)
                    .accessibilityLabel("Send message")
                }
                .padding(12)
                .background(.bar)
            }
            .navigationTitle("AI")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showingModelSheet = true } label: {
                        Label(model.selectedModel?.name ?? "Choose model", systemImage: "brain.head.profile")
                            .lineLimit(1)
                    }
                    .accessibilityLabel("Choose AI model")
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button { model.clearChat() } label: { Image(systemName: "trash") }
                        .disabled(model.messages.isEmpty)
                        .accessibilityLabel("Clear chat")
                }
            }
            .sheet(isPresented: $showingModelSheet) { modelSheet }
            .onDrop(of: [UTType.fileURL.identifier, UTType.item.identifier], isTargeted: nil) { providers in
                guard let provider = providers.first else { return false }
                provider.loadFileRepresentation(forTypeIdentifier: UTType.item.identifier) { url, _ in
                    guard let url else { return }
                    let stagingURL = FileManager.default.temporaryDirectory
                        .appendingPathComponent(UUID().uuidString)
                        .appendingPathExtension(url.pathExtension)
                    try? FileManager.default.copyItem(at: url, to: stagingURL)
                    Task { @MainActor in
                        _ = model.importWorkspaceModel(from: stagingURL)
                        try? FileManager.default.removeItem(at: stagingURL)
                    }
                }
                return true
            }
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("Private AI workspace", systemImage: "brain.head.profile")
        } description: {
            Text("Choose a model, import its model file, and start a local chat. Workspace keeps model files in its private storage.")
        } actions: {
            Button("Choose model") { showingModelSheet = true }
                .buttonStyle(.borderedProminent)
            Text(model.status).font(.footnote).foregroundStyle(.secondary)
        }
    }

    private var modelSheet: some View {
        NavigationStack {
            List {
                Section("Models") {
                    ForEach(model.models) { item in
                        Button { model.select(item); showingModelSheet = false } label: {
                            HStack(spacing: 12) {
                                Image(systemName: item.isInstalled ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(item.isInstalled ? .green : .secondary)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(item.name).font(.headline)
                                    Text("\(item.provider) · \(item.size)").font(.caption).foregroundStyle(.secondary)
                                    Text(item.summary).font(.caption2).foregroundStyle(.tertiary)
                                }
                                Spacer()
                                if item.id == model.selectedModelID { Image(systemName: "checkmark").foregroundStyle(.tint) }
                            }
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            if item.isInstalled { Button("Remove model", role: .destructive) { model.remove(item) } }
                        }
                    }
                }
                Section("Selected model") {
                    Label("Choose from Workspace Files", systemImage: "folder.fill")
                    Text(model.status).font(.footnote).foregroundStyle(.secondary)
                    Text("Share or drag a model into Workspace Files/AI Models, then select it here. Model weights are external assets; the app does not claim a model is ready until it can read the file.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                let workspaceFiles = model.workspaceModelFiles()
                if !workspaceFiles.isEmpty {
                    Section("Workspace Files") {
                        ForEach(workspaceFiles, id: \.path) { file in
                            Button {
                                _ = model.importModel(from: file)
                                showingModelSheet = false
                            } label: {
                                Label(file.lastPathComponent, systemImage: "doc.fill")
                                    .lineLimit(1)
                            }
                        }
                    }
                }
            }
            .navigationTitle("AI models")
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { showingModelSheet = false } } }
        }
    }
}

private struct WorkspaceAIMessageBubble: View {
    let message: WorkspaceAIChatMessage

    var body: some View {
        HStack {
            if message.role == .assistant { bubble; Spacer(minLength: 42) } else { Spacer(minLength: 42); bubble }
        }
    }

    private var bubble: some View {
        Text(message.text)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .foregroundStyle(message.role == .user ? .white : .primary)
            .background(message.role == .user ? Color.accentColor : Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .textSelection(.enabled)
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

/// A command that a guest-side Gadget can consume from the authenticated MCP
/// bridge. The host never synthesizes private UIKit touch events for a guest
/// process; commands are scoped to the snapshot that produced their token.
struct WorkspaceGuestControlCommand: Identifiable, Codable, Hashable {
    let id: UUID
    let createdAt: Date
    let kind: String
    let snapshotID: String
    let elementToken: String?
    let payload: String
}

@MainActor
final class WorkspaceGuestSessionStore: ObservableObject {
    static let shared = WorkspaceGuestSessionStore()

    @Published private(set) var appName: String?
    @Published private(set) var bundleIdentifier: String?
    @Published private(set) var sessionID = UUID().uuidString.lowercased()
    @Published private(set) var isActive = false
    @Published private(set) var isBridgeConnected = false
    @Published private(set) var logs: [WorkspaceGuestLogEntry] = []
    @Published private(set) var evaluations: [WorkspaceGuestEvaluation] = []
    @Published private(set) var controlCommands: [WorkspaceGuestControlCommand] = []

    private init() {}

    func start(appName: String, bundleIdentifier: String) {
        if isActive, self.appName == appName, self.bundleIdentifier == bundleIdentifier {
            return
        }
        self.appName = appName
        self.bundleIdentifier = bundleIdentifier
        self.sessionID = UUID().uuidString.lowercased()
        isActive = true
        logs = []
        evaluations = []
        controlCommands = []
        isBridgeConnected = false
        appendLog("Started guest session for \(appName).", level: "system")
    }

    func stop(reason: String? = nil) {
        if let reason, !reason.isEmpty { appendLog(reason, level: "error") }
        isActive = false
        controlCommands = []
        isBridgeConnected = false
    }

    func appendLog(_ message: String, level: String = "info") {
        let cleaned = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }
        logs.append(WorkspaceGuestLogEntry(id: UUID(), date: .now, level: level, message: cleaned))
        if logs.count > 500 { logs.removeFirst(logs.count - 500) }
    }

    func setBridgeConnected(_ connected: Bool) {
        guard isBridgeConnected != connected else { return }
        isBridgeConnected = connected
        appendLog(connected ? "Guest Frida bridge connected." : "Guest Frida bridge disconnected.", level: "system")
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

    @discardableResult
    func submitControlCommand(kind: String, snapshotID: String, elementToken: String?, payload: [String: Any]) -> UUID {
        let command = WorkspaceGuestControlCommand(
            id: UUID(),
            createdAt: .now,
            kind: kind,
            snapshotID: snapshotID,
            elementToken: elementToken,
            payload: (try? JSONSerialization.data(withJSONObject: payload)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        )
        controlCommands.append(command)
        if controlCommands.count > 100 { controlCommands.removeFirst(controlCommands.count - 100) }
        appendLog("Queued guest \(kind) command \(command.id.uuidString.prefix(8)).", level: "control")
        return command.id
    }

    func pendingControlCommands() -> [[String: Any]] {
        controlCommands.map { command in
            var value: [String: Any] = [
                "id": command.id.uuidString,
                "createdAt": command.createdAt.ISO8601Format(),
                "kind": command.kind,
                "snapshotID": command.snapshotID,
                "payload": command.payload
            ]
            if let elementToken = command.elementToken { value["elementToken"] = elementToken }
            return value
        }
    }

    func completeControlCommand(id: UUID, result: String? = nil, error: String? = nil) {
        controlCommands.removeAll { $0.id == id }
        if let error { appendLog("Guest control failed: \(error)", level: "error") }
        else if let result { appendLog(result, level: "control") }
    }

    func snapshot() -> [String: Any] {
        [
            "active": isActive,
            "app": appName ?? "",
            "bundleIdentifier": bundleIdentifier ?? "",
            "sessionID": sessionID,
            "bridgeConnected": isBridgeConnected,
            "logCount": logs.count,
            "pendingEvaluations": evaluations.filter { $0.result == nil && $0.error == nil }.count,
            "pendingControlCommands": controlCommands.count
        ]
    }
}

// MARK: - CUA-style guest state and control

private struct WorkspaceGuestControlSnapshot {
    let id: String
    let sessionID: String
    let sessionApp: String
    let rootView: UIView
    var elements: [String: UIView]
}

@MainActor
final class WorkspaceGuestControlCenter {
    static let shared = WorkspaceGuestControlCenter()
    private var snapshots: [String: WorkspaceGuestControlSnapshot] = [:]
    private let maxElements = 350
    private let maxScreenshotDimension: CGFloat = 2_048
    private let maxScreenshotBytes = 6 * 1_024 * 1_024
    private weak var registeredGuestView: UIView?

    private init() {}

    func registerGuestView(_ view: UIView, bundleIdentifier: String) {
        registeredGuestView = view
    }

    func unregisterGuestView(_ view: UIView) {
        guard registeredGuestView === view else { return }
        registeredGuestView = nil
        snapshots.removeAll()
    }

    func state(arguments: [String: Any]) -> (status: String, body: [String: Any]) {
        guard WorkspaceGuestSessionStore.shared.isActive else {
            return ("409 Conflict", refusal("no_active_guest", "No LiveContainer guest is active."))
        }
        let includeScreenshot = arguments["include_screenshot"] as? Bool ?? true
        let includeTree = arguments["include_tree"] as? Bool ?? true
        guard let view = activeGuestView() else {
            return ("501 Not Implemented", refusal("native_runtime_unavailable", "The native LiveContainer guest view is unavailable in this build."))
        }
        let id = UUID().uuidString.lowercased()
        var snapshot = WorkspaceGuestControlSnapshot(id: id, sessionID: WorkspaceGuestSessionStore.shared.sessionID, sessionApp: WorkspaceGuestSessionStore.shared.appName ?? "", rootView: view, elements: [:])
        let viewport = ["width": view.bounds.width, "height": view.bounds.height, "scale": UIScreen.main.scale] as [String: Any]
        var body: [String: Any] = [
            "snapshot_id": id,
            "session_id": snapshot.sessionID,
            "app": snapshot.sessionApp,
            "bundleIdentifier": WorkspaceGuestSessionStore.shared.bundleIdentifier ?? "",
            "viewport": viewport,
            "screenshot_width": view.bounds.width,
            "screenshot_height": view.bounds.height,
            "screenshot_scale": UIScreen.main.scale,
            "screenshot_mime": "image/png",
            "degraded": !WorkspaceGuestSessionStore.shared.isBridgeConnected,
            "capabilities": [
                "screenshot": true,
                "semantic_tree": false,
                "guest_bridge_commands": WorkspaceGuestSessionStore.shared.isBridgeConnected
            ]
        ]
        if !WorkspaceGuestSessionStore.shared.isBridgeConnected {
            body["degraded_reason"] = "guest_bridge_not_connected"
        }
        // Host-side views render the guest surface but do not reliably expose
        // its accessibility hierarchy. The Frida bridge is the source of truth
        // for guest semantics; this limited tree only describes host controls.
        if includeTree { body["elements"] = hostElements(for: view, snapshot: &snapshot) }
        if includeScreenshot {
            guard let image = imageData(for: view) else {
                return ("503 Service Unavailable", refusal("screenshot_unavailable", "The active guest surface could not be rendered."))
            }
            body["screenshot_base64"] = image.base64EncodedString()
            body["screenshot_bytes"] = image.count
        }
        snapshots = [id: snapshot] // A new state invalidates all previous element tokens.
        return ("200 OK", body)
    }

    func screenshot(arguments: [String: Any]) -> (status: String, body: [String: Any]) {
        guard let snapshot = validatedSnapshot(arguments), let data = imageData(for: snapshot.rootView) else {
            return ("409 Conflict", refusal("stale_or_unavailable_snapshot", "Capture guest_state first and use its snapshot_id."))
        }
        return ("200 OK", ["snapshot_id": snapshot.id, "app": snapshot.sessionApp, "image_base64": data.base64EncodedString(), "format": "png", "bytes": data.count])
    }

    func action(tool: String, arguments: [String: Any]) -> (status: String, body: [String: Any]) {
        guard let snapshot = validatedSnapshot(arguments) else {
            return ("409 Conflict", refusal("stale_snapshot", "The snapshot is stale. Capture guest_state again."))
        }
        guard WorkspaceGuestSessionStore.shared.isBridgeConnected else {
            return ("501 Not Implemented", refusal("capability_unavailable", "The guest has not connected its Frida control bridge."))
        }
        let elementToken = arguments["element_token"] as? String
        if let elementToken, snapshot.elements[elementToken] == nil {
            return ("409 Conflict", refusal("stale_element_token", "The element token is not part of this snapshot."))
        }
        switch tool {
        case "guest_tap":
            guard elementToken != nil || validPixelPoint(arguments, in: snapshot.rootView) else {
                return ("400 Bad Request", refusal("invalid_coordinate_space", "Provide a snapshot element token or pixel x and y within the returned viewport."))
            }
            let payload = ["x": arguments["x"] ?? NSNull(), "y": arguments["y"] ?? NSNull()]
            let id = WorkspaceGuestSessionStore.shared.submitControlCommand(kind: "tap", snapshotID: snapshot.id, elementToken: elementToken, payload: payload)
            return ("202 Accepted", queued(id, snapshot.id, "tap"))
        case "guest_swipe":
            guard let from = point(arguments["from"]), let to = point(arguments["to"]) else { return ("400 Bad Request", refusal("invalid_coordinates", "from and to must be [x, y] arrays.")) }
            guard [from.0, from.1, to.0, to.1].allSatisfy({ $0 >= 0 && $0 <= 1 }) else { return ("400 Bad Request", refusal("invalid_coordinates", "Coordinates must be normalized between 0 and 1.")) }
            let payload: [String: Any] = ["from": [from.0, from.1], "to": [to.0, to.1], "duration_ms": arguments["duration_ms"] ?? 350]
            let id = WorkspaceGuestSessionStore.shared.submitControlCommand(kind: "swipe", snapshotID: snapshot.id, elementToken: elementToken, payload: payload)
            return ("202 Accepted", queued(id, snapshot.id, "swipe"))
        case "guest_type":
            guard let text = arguments["text"] as? String else { return ("400 Bad Request", refusal("missing_text", "text is required.")) }
            let id = WorkspaceGuestSessionStore.shared.submitControlCommand(kind: "type", snapshotID: snapshot.id, elementToken: elementToken, payload: ["text": text])
            return ("202 Accepted", queued(id, snapshot.id, "type"))
        case "guest_key":
            guard let key = arguments["key"] as? String, !key.isEmpty else { return ("400 Bad Request", refusal("missing_key", "key is required.")) }
            let id = WorkspaceGuestSessionStore.shared.submitControlCommand(kind: "key", snapshotID: snapshot.id, elementToken: elementToken, payload: ["key": key])
            return ("202 Accepted", queued(id, snapshot.id, "key"))
        case "guest_double_tap", "guest_long_press", "guest_scroll", "guest_set_text",
             "guest_focus", "guest_keyboard", "guest_clipboard", "guest_clipboard_get", "guest_clipboard_set", "guest_accessibility_snapshot",
             "guest_runtime_info", "guest_metrics", "guest_filesystem":
            let kind = String(tool.dropFirst("guest_".count))
            var payload = arguments
            payload.removeValue(forKey: "snapshot_id")
            payload.removeValue(forKey: "element_token")
            let id = WorkspaceGuestSessionStore.shared.submitControlCommand(kind: kind, snapshotID: snapshot.id, elementToken: elementToken, payload: payload)
            return ("202 Accepted", queued(id, snapshot.id, kind))
        default:
            return ("400 Bad Request", refusal("unknown_control", "Unsupported guest control tool."))
        }
    }

    private func activeGuestView() -> UIView? {
        if let registeredGuestView { return registeredGuestView }
#if LIVE_CONTAINER_NATIVE
        let name = WorkspaceGuestSessionStore.shared.appName
        return MultitaskDockManager.shared.apps.first(where: { app in
            guard let name else { return true }
            return app.appName == name
        })?.view
#else
        return nil
#endif
    }

    private func validatedSnapshot(_ arguments: [String: Any]) -> WorkspaceGuestControlSnapshot? {
        guard WorkspaceGuestSessionStore.shared.isActive,
              let id = arguments["snapshot_id"] as? String,
              let snapshot = snapshots[id], snapshot.sessionID == WorkspaceGuestSessionStore.shared.sessionID,
              snapshot.sessionApp == (WorkspaceGuestSessionStore.shared.appName ?? "") else { return nil }
        return snapshot
    }

    private func hostElements(for view: UIView, snapshot: inout WorkspaceGuestControlSnapshot) -> [[String: Any]] {
        func walk(_ node: UIView, path: String) -> [String: Any] {
            guard snapshot.elements.count < maxElements else { return ["truncated": true] }
            let token = "\(snapshot.id).\(path)"
            snapshot.elements[token] = node
            let frame = node.convert(node.bounds, to: view)
            var value: [String: Any] = [
                "element_token": token,
                "type": String(describing: type(of: node)),
                "frame": ["x": frame.minX, "y": frame.minY, "width": frame.width, "height": frame.height],
                "visible": !node.isHidden && node.alpha > 0.01,
                "enabled": (node as? UIControl)?.isEnabled ?? true
            ]
            if let label = node.accessibilityLabel, !label.isEmpty { value["label"] = label }
            if let identifier = node.accessibilityIdentifier, !identifier.isEmpty { value["identifier"] = identifier }
            if let button = node as? UIButton, let title = button.currentTitle, !title.isEmpty { value["title"] = title }
            let children = node.subviews.enumerated().prefix(maxElements - snapshot.elements.count).map { walk($0.element, path: "\(path).\($0.offset)") }
            if !children.isEmpty { value["children"] = children }
            return value
        }
        return [walk(view, path: "0")]
    }

    private func imageData(for view: UIView) -> Data? {
        guard view.bounds.width > 0, view.bounds.height > 0 else { return nil }
        let format = UIGraphicsImageRendererFormat()
        let ratio = min(1, maxScreenshotDimension / max(view.bounds.width, view.bounds.height))
        format.scale = max(1, UIScreen.main.scale * ratio)
        format.opaque = true
        let image = UIGraphicsImageRenderer(bounds: view.bounds, format: format).image { _ in
            view.drawHierarchy(in: view.bounds, afterScreenUpdates: true)
        }
        guard let data = image.pngData(), data.count <= maxScreenshotBytes else { return nil }
        return data
    }

    private func point(_ value: Any?) -> (Double, Double)? {
        if let values = value as? [Double], values.count >= 2 { return (values[0], values[1]) }
        if let values = value as? [Any], values.count >= 2, let x = values[0] as? NSNumber, let y = values[1] as? NSNumber { return (x.doubleValue, y.doubleValue) }
        return nil
    }

    private func validPixelPoint(_ arguments: [String: Any], in view: UIView) -> Bool {
        guard let x = (arguments["x"] as? NSNumber)?.doubleValue,
              let y = (arguments["y"] as? NSNumber)?.doubleValue else { return false }
        return x >= 0 && y >= 0 && x <= view.bounds.width && y <= view.bounds.height
    }

    private func refusal(_ code: String, _ message: String) -> [String: Any] { ["effect": "refused", "route": "host", "refusal_code": code, "message": message, "evidence": NSNull()] }
    private func queued(_ id: UUID, _ snapshotID: String, _ kind: String) -> [String: Any] { ["effect": "partial", "route": "frida_gadget", "command_id": id.uuidString, "snapshot_id": snapshotID, "kind": kind, "evidence": ["pending": true], "escalation": "Wait for /guest/control/result, then capture guest_state to verify the visible result." ] }
}

@MainActor
func guestControlResponse(tool: String, arguments: [String: Any]) -> Data {
    let result: (status: String, body: [String: Any])
    if tool == "guest_state" { result = WorkspaceGuestControlCenter.shared.state(arguments: arguments) }
    else if tool == "guest_screenshot" { result = WorkspaceGuestControlCenter.shared.screenshot(arguments: arguments) }
    else { result = WorkspaceGuestControlCenter.shared.action(tool: tool, arguments: arguments) }
    let body = (try? JSONSerialization.data(withJSONObject: result.body, options: [.sortedKeys])) ?? Data("{\"error\":\"Encoding failure\"}".utf8)
    var response = Data("HTTP/1.1 \(result.status)\r\nContent-Type: application/json; charset=utf-8\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8)
    response.append(body)
    return response
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

// MARK: - Guest lifecycle, task metadata, and metrics

enum WorkspaceGuestLifecycleState: String, Codable, CaseIterable, Hashable {
    case idle
    case launching
    case running
    case paused
    case stopping
    case stopped
    case failed
}

enum WorkspaceGuestTaskState: String, Codable, CaseIterable, Hashable {
    case queued
    case running
    case succeeded
    case failed
    case cancelled
}

struct WorkspaceGuestTaskMetadata: Identifiable, Codable, Hashable {
    let id: UUID
    let sessionID: String
    let appName: String
    let bundleIdentifier: String
    let operation: String
    let createdAt: Date
    var startedAt: Date?
    var completedAt: Date?
    var state: WorkspaceGuestTaskState
    var progress: Double
    var detail: String
    var error: String?

    init(
        id: UUID = UUID(),
        sessionID: String,
        appName: String,
        bundleIdentifier: String,
        operation: String,
        createdAt: Date = .now,
        state: WorkspaceGuestTaskState = .queued,
        progress: Double = 0,
        detail: String = "Queued"
    ) {
        self.id = id
        self.sessionID = sessionID
        self.appName = appName
        self.bundleIdentifier = bundleIdentifier
        self.operation = operation
        self.createdAt = createdAt
        self.startedAt = nil
        self.completedAt = nil
        self.state = state
        self.progress = min(1, max(0, progress))
        self.detail = detail
        self.error = nil
    }
}

@MainActor
final class WorkspaceGuestTaskStore: ObservableObject {
    static let shared = WorkspaceGuestTaskStore()

    @Published private(set) var tasks: [WorkspaceGuestTaskMetadata]

    private let defaultsKey = "workspace.guestTasks.v1"
    private let maximumTasks = 250

    private init() {
        if let data = UserDefaults.standard.data(forKey: defaultsKey),
           let saved = try? JSONDecoder().decode([WorkspaceGuestTaskMetadata].self, from: data) {
            tasks = saved
        } else {
            tasks = []
        }
        prune()
    }

    @discardableResult
    func enqueue(sessionID: String, appName: String, bundleIdentifier: String, operation: String, detail: String = "Queued") -> UUID {
        let task = WorkspaceGuestTaskMetadata(
            sessionID: sessionID,
            appName: appName,
            bundleIdentifier: bundleIdentifier,
            operation: operation,
            detail: detail
        )
        tasks.append(task)
        prune()
        persist()
        return task.id
    }

    func start(_ id: UUID, detail: String = "Running") {
        update(id) { task in
            task.state = .running
            task.startedAt = task.startedAt ?? .now
            task.progress = max(task.progress, 0.01)
            task.detail = detail
            task.error = nil
        }
    }

    func update(_ id: UUID, progress: Double? = nil, detail: String? = nil) {
        update(id) { task in
            if let progress { task.progress = min(1, max(0, progress)) }
            if let detail { task.detail = detail }
        }
    }

    func succeed(_ id: UUID, detail: String = "Completed") {
        update(id) { task in
            task.state = .succeeded
            task.progress = 1
            task.completedAt = .now
            task.detail = detail
            task.error = nil
        }
    }

    func fail(_ id: UUID, error: String, detail: String = "Failed") {
        update(id) { task in
            task.state = .failed
            task.completedAt = .now
            task.detail = detail
            task.error = error
        }
    }

    func cancel(_ id: UUID, detail: String = "Cancelled") {
        update(id) { task in
            task.state = .cancelled
            task.completedAt = .now
            task.detail = detail
        }
    }

    func tasks(for sessionID: String) -> [WorkspaceGuestTaskMetadata] {
        tasks.filter { $0.sessionID == sessionID }.sorted { $0.createdAt > $1.createdAt }
    }

    func remove(_ id: UUID) {
        tasks.removeAll { $0.id == id }
        persist()
    }

    private func update(_ id: UUID, mutation: (inout WorkspaceGuestTaskMetadata) -> Void) {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }
        mutation(&tasks[index])
        persist()
    }

    private func prune() {
        guard tasks.count > maximumTasks else { return }
        tasks.sort { $0.createdAt > $1.createdAt }
        tasks = Array(tasks.prefix(maximumTasks))
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(tasks) else { return }
        UserDefaults.standard.set(data, forKey: defaultsKey)
    }
}

@MainActor
final class WorkspaceGuestLifecycleCoordinator: ObservableObject {
    static let shared = WorkspaceGuestLifecycleCoordinator()

    @Published private(set) var state: WorkspaceGuestLifecycleState = .idle
    @Published private(set) var activeTaskID: UUID?
    @Published private(set) var lastError: String?

    private init() {}

    func beginLaunch(appName: String, bundleIdentifier: String, operation: String = "launch") {
        WorkspaceGuestSessionStore.shared.start(appName: appName, bundleIdentifier: bundleIdentifier)
        let session = WorkspaceGuestSessionStore.shared
        activeTaskID = WorkspaceGuestTaskStore.shared.enqueue(
            sessionID: session.sessionID,
            appName: appName,
            bundleIdentifier: bundleIdentifier,
            operation: operation,
            detail: "Waiting for LiveContainer"
        )
        if let activeTaskID { WorkspaceGuestTaskStore.shared.start(activeTaskID, detail: "Launching guest") }
        state = .launching
        lastError = nil
        session.appendLog("Launch requested for \(appName).", level: "system")
    }

    func markRunning(detail: String = "Guest running") {
        state = .running
        if let activeTaskID { WorkspaceGuestTaskStore.shared.update(activeTaskID, progress: 0.5, detail: detail) }
        WorkspaceGuestSessionStore.shared.setBridgeConnected(true)
    }

    func pause(detail: String = "Paused by user") {
        guard state == .running else { return }
        state = .paused
        if let activeTaskID { WorkspaceGuestTaskStore.shared.update(activeTaskID, detail: detail) }
        WorkspaceGuestSessionStore.shared.appendLog(detail, level: "system")
    }

    func resume(detail: String = "Resumed") {
        guard state == .paused else { return }
        state = .running
        if let activeTaskID { WorkspaceGuestTaskStore.shared.update(activeTaskID, detail: detail) }
        WorkspaceGuestSessionStore.shared.appendLog(detail, level: "system")
    }

    func fail(_ message: String) {
        state = .failed
        lastError = message
        if let activeTaskID { WorkspaceGuestTaskStore.shared.fail(activeTaskID, error: message) }
        WorkspaceGuestSessionStore.shared.appendLog(message, level: "error")
    }

    func stop(reason: String = "Stopped by user") {
        guard state != .idle && state != .stopped else { return }
        state = .stopping
        if let activeTaskID { WorkspaceGuestTaskStore.shared.succeed(activeTaskID, detail: reason) }
        WorkspaceGuestSessionStore.shared.stop(reason: reason)
        activeTaskID = nil
        state = .stopped
    }
}

struct WorkspaceGuestMetricSample: Identifiable, Codable, Hashable {
    let id: UUID
    let sessionID: String
    let timestamp: Date
    let cpuPercent: Double?
    let memoryBytes: UInt64?
    let frameRate: Double?
    let networkBytes: UInt64?
    let note: String?

    init(
        sessionID: String,
        timestamp: Date = .now,
        cpuPercent: Double? = nil,
        memoryBytes: UInt64? = nil,
        frameRate: Double? = nil,
        networkBytes: UInt64? = nil,
        note: String? = nil
    ) {
        self.id = UUID()
        self.sessionID = sessionID
        self.timestamp = timestamp
        self.cpuPercent = cpuPercent
        self.memoryBytes = memoryBytes
        self.frameRate = frameRate
        self.networkBytes = networkBytes
        self.note = note
    }
}

@MainActor
final class WorkspaceGuestMetricsStore: ObservableObject {
    static let shared = WorkspaceGuestMetricsStore()

    @Published private(set) var samples: [WorkspaceGuestMetricSample] = []
    private let defaultsKey = "workspace.guestMetrics.v1"
    private let maximumSamples = 300

    private init() {
        if let data = UserDefaults.standard.data(forKey: defaultsKey),
           let saved = try? JSONDecoder().decode([WorkspaceGuestMetricSample].self, from: data) {
            samples = saved
        }
        prune()
    }

    func append(_ sample: WorkspaceGuestMetricSample) {
        samples.append(sample)
        prune()
        persist()
    }

    func samples(for sessionID: String) -> [WorkspaceGuestMetricSample] {
        samples.filter { $0.sessionID == sessionID }.sorted { $0.timestamp < $1.timestamp }
    }

    func latest(for sessionID: String) -> WorkspaceGuestMetricSample? {
        samples.filter { $0.sessionID == sessionID }.max { $0.timestamp < $1.timestamp }
    }

    func clear(sessionID: String? = nil) {
        if let sessionID { samples.removeAll { $0.sessionID == sessionID } }
        else { samples.removeAll() }
        persist()
    }

    private func prune() {
        guard samples.count > maximumSamples else { return }
        samples.sort { $0.timestamp > $1.timestamp }
        samples = Array(samples.prefix(maximumSamples))
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(samples) else { return }
        UserDefaults.standard.set(data, forKey: defaultsKey)
    }
}

// MARK: - Active-guest scoped filesystem

struct WorkspaceGuestFileEntry: Identifiable, Codable, Hashable {
    let id: String
    let relativePath: String
    let isDirectory: Bool
    let byteCount: UInt64
    let modifiedAt: Date?
}

enum WorkspaceGuestFilesystemError: LocalizedError {
    case noActiveGuest
    case pathEscapesRoot
    case missingPath
    case notDirectory
    case readLimitExceeded
    case writeLimitExceeded
    case invalidText

    var errorDescription: String? {
        switch self {
        case .noActiveGuest: return "No LiveContainer guest is active."
        case .pathEscapesRoot: return "The path must stay inside the active guest workspace."
        case .missingPath: return "The guest path does not exist."
        case .notDirectory: return "The guest path is not a directory."
        case .readLimitExceeded: return "The file exceeds the 2 MiB read limit."
        case .writeLimitExceeded: return "The file exceeds the 2 MiB write limit."
        case .invalidText: return "The file is not valid UTF-8 text."
        }
    }
}

/// A mirror workspace for the active guest. It intentionally never accepts an
/// arbitrary app identifier, and every path is checked after symlink resolution.
/// The native guest's private sandbox remains inaccessible unless its Gadget
/// explicitly exposes a file operation through the guest bridge.
struct WorkspaceGuestFilesystem {
    let rootDirectory: URL
    let sessionID: String

    private let fileManager = FileManager.default
    private let maximumReadBytes: UInt64 = 2 * 1_024 * 1_024
    private let maximumWriteBytes: UInt64 = 2 * 1_024 * 1_024

    @MainActor
    static func active(baseDirectory: URL? = nil) throws -> WorkspaceGuestFilesystem {
        let session = WorkspaceGuestSessionStore.shared
        guard session.isActive, let bundle = session.bundleIdentifier, !bundle.isEmpty else {
            throw WorkspaceGuestFilesystemError.noActiveGuest
        }
        let documents = baseDirectory ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let workspace = documents.appendingPathComponent("Workspace Files", isDirectory: true)
        let guestName = bundle.unicodeScalars.map { scalar -> String in
            let allowed = CharacterSet.alphanumerics
            return allowed.contains(scalar) ? String(scalar) : "_"
        }.joined()
        let root = workspace
            .appendingPathComponent("Guest Sandboxes", isDirectory: true)
            .appendingPathComponent(guestName.isEmpty ? "Guest" : guestName, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return WorkspaceGuestFilesystem(rootDirectory: root, sessionID: session.sessionID)
    }

    func list(relativePath: String = "") throws -> [WorkspaceGuestFileEntry] {
        let directory = try resolve(relativePath, requireExisting: true)
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory) else { throw WorkspaceGuestFilesystemError.missingPath }
        guard isDirectory.boolValue else { throw WorkspaceGuestFilesystemError.notDirectory }
        let urls = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )
        return try urls.sorted { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }.map { url in
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey])
            let relative = self.relativePath(for: url)
            return WorkspaceGuestFileEntry(
                id: relative,
                relativePath: relative,
                isDirectory: values.isDirectory ?? false,
                byteCount: UInt64(values.fileSize ?? 0),
                modifiedAt: values.contentModificationDate
            )
        }
    }

    func readText(relativePath: String) throws -> String {
        let url = try resolve(relativePath, requireExisting: true)
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
              UInt64(values.fileSize ?? 0) <= maximumReadBytes else { throw WorkspaceGuestFilesystemError.readLimitExceeded }
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        guard UInt64(data.count) <= maximumReadBytes, let text = String(data: data, encoding: .utf8) else { throw WorkspaceGuestFilesystemError.invalidText }
        return text
    }

    func writeText(_ text: String, relativePath: String) throws {
        guard let data = text.data(using: .utf8), UInt64(data.count) <= maximumWriteBytes else { throw WorkspaceGuestFilesystemError.writeLimitExceeded }
        let url = try resolve(relativePath, requireExisting: false)
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    func makeDirectory(relativePath: String) throws {
        let url = try resolve(relativePath, requireExisting: false)
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func remove(relativePath: String) throws {
        let url = try resolve(relativePath, requireExisting: true)
        guard url != rootDirectory else { throw WorkspaceGuestFilesystemError.pathEscapesRoot }
        try fileManager.removeItem(at: url)
    }

    private func resolve(_ relativePath: String, requireExisting: Bool) throws -> URL {
        let candidate = rootDirectory.appendingPathComponent(relativePath, isDirectory: false).standardizedFileURL
        let root = rootDirectory.standardizedFileURL
        guard candidate.path == root.path || candidate.path.hasPrefix(root.path + "/") else { throw WorkspaceGuestFilesystemError.pathEscapesRoot }
        if requireExisting {
            guard fileManager.fileExists(atPath: candidate.path) else { throw WorkspaceGuestFilesystemError.missingPath }
            let resolved = candidate.resolvingSymlinksInPath().standardizedFileURL
            guard resolved.path == root.path || resolved.path.hasPrefix(root.path + "/") else { throw WorkspaceGuestFilesystemError.pathEscapesRoot }
            return resolved
        }
        let parent = candidate.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL
        guard parent.path == root.path || parent.path.hasPrefix(root.path + "/") else { throw WorkspaceGuestFilesystemError.pathEscapesRoot }
        return candidate
    }

    private func relativePath(for url: URL) -> String {
        let rootPath = rootDirectory.standardizedFileURL.path
        let value = url.standardizedFileURL.path
        guard value.hasPrefix(rootPath + "/") else { return url.lastPathComponent }
        return String(value.dropFirst(rootPath.count + 1))
    }
}

// MARK: - Persisted workflows and macros

enum WorkspaceWorkflowAction: String, Codable, CaseIterable, Hashable {
    case captureGuestState
    case refreshGuestLogs
    case executeGuestScript
    case copyWorkspaceFile
    case buildGitHubActions
    case openRemoteDesktop
    case waitForBridge
}

struct WorkspaceWorkflowStep: Identifiable, Codable, Hashable {
    let id: UUID
    var action: WorkspaceWorkflowAction
    var title: String
    var parameters: [String: String]
    var enabled: Bool

    init(id: UUID = UUID(), action: WorkspaceWorkflowAction, title: String, parameters: [String: String] = [:], enabled: Bool = true) {
        self.id = id
        self.action = action
        self.title = title
        self.parameters = parameters
        self.enabled = enabled
    }
}

struct WorkspaceWorkflowDefinition: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String
    var createdAt: Date
    var updatedAt: Date
    var steps: [WorkspaceWorkflowStep]
    var enabled: Bool
    var lastRunAt: Date?
    var lastRunState: WorkspaceGuestTaskState?

    init(id: UUID = UUID(), name: String, steps: [WorkspaceWorkflowStep] = []) {
        self.id = id
        self.name = name
        self.createdAt = .now
        self.updatedAt = .now
        self.steps = steps
        self.enabled = true
        self.lastRunAt = nil
        self.lastRunState = nil
    }
}

@MainActor
final class WorkspaceWorkflowStore: ObservableObject {
    static let shared = WorkspaceWorkflowStore()

    @Published private(set) var workflows: [WorkspaceWorkflowDefinition]
    private let defaultsKey = "workspace.workflows.v1"

    private init() {
        if let data = UserDefaults.standard.data(forKey: defaultsKey),
           let saved = try? JSONDecoder().decode([WorkspaceWorkflowDefinition].self, from: data) {
            workflows = saved
        } else {
            workflows = [Self.defaultGuestDiagnostics]
            persist()
        }
    }

    func upsert(_ workflow: WorkspaceWorkflowDefinition) {
        var value = workflow
        value.updatedAt = .now
        if let index = workflows.firstIndex(where: { $0.id == value.id }) { workflows[index] = value }
        else { workflows.append(value) }
        persist()
    }

    @discardableResult
    func create(name: String, steps: [WorkspaceWorkflowStep] = []) -> UUID {
        let workflow = WorkspaceWorkflowDefinition(name: name.isEmpty ? "Untitled workflow" : name, steps: steps)
        workflows.append(workflow)
        persist()
        return workflow.id
    }

    @discardableResult
    func duplicate(_ id: UUID) -> UUID? {
        guard let source = workflows.first(where: { $0.id == id }) else { return nil }
        var copy = WorkspaceWorkflowDefinition(name: "(source.name) Copy", steps: source.steps)
        copy.enabled = source.enabled
        workflows.append(copy)
        persist()
        return copy.id
    }

    func remove(_ id: UUID) {
        workflows.removeAll { $0.id == id }
        persist()
    }

    func recordRun(_ id: UUID, state: WorkspaceGuestTaskState) {
        guard let index = workflows.firstIndex(where: { $0.id == id }) else { return }
        workflows[index].lastRunAt = .now
        workflows[index].lastRunState = state
        workflows[index].updatedAt = .now
        persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(workflows) else { return }
        UserDefaults.standard.set(data, forKey: defaultsKey)
    }

    private static let defaultGuestDiagnostics = WorkspaceWorkflowDefinition(
        name: "Guest diagnostics",
        steps: [
            WorkspaceWorkflowStep(action: .captureGuestState, title: "Capture guest state"),
            WorkspaceWorkflowStep(action: .refreshGuestLogs, title: "Refresh logs"),
            WorkspaceWorkflowStep(action: .waitForBridge, title: "Wait for Frida bridge", parameters: ["timeout_seconds": "15"])
        ]
    )
}

// MARK: - Repository and installer inspection

struct WorkspaceRepositoryAppInspection: Identifiable, Codable, Hashable {
    let id: String
    let name: String
    let bundleIdentifier: String?
    let version: String?
    let category: String?
    let downloadURL: URL?
    let iconURL: URL?
    let byteCount: UInt64?
}

struct WorkspaceRepositoryInspection: Codable, Hashable {
    let sourceURL: URL?
    let name: String
    let apps: [WorkspaceRepositoryAppInspection]
    let inspectedAt: Date
}

enum WorkspaceRepositoryInspectionError: LocalizedError {
    case invalidJSON
    case unsupportedFormat
    case requestFailed

    var errorDescription: String? {
        switch self {
        case .invalidJSON: return "The repository did not contain valid JSON."
        case .unsupportedFormat: return "The repository format is not recognized."
        case .requestFailed: return "The repository could not be loaded."
        }
    }
}

struct WorkspaceRepositoryInspector {
    static func inspect(data: Data, sourceURL: URL? = nil) throws -> WorkspaceRepositoryInspection {
        guard let object = try? JSONSerialization.jsonObject(with: data) else { throw WorkspaceRepositoryInspectionError.invalidJSON }
        let root: [String: Any]
        let rawApps: [[String: Any]]
        if let dictionary = object as? [String: Any] {
            root = dictionary
            if let apps = dictionary["apps"] as? [[String: Any]] { rawApps = apps }
            else if let apps = dictionary["applications"] as? [[String: Any]] { rawApps = apps }
            else { throw WorkspaceRepositoryInspectionError.unsupportedFormat }
        } else if let apps = object as? [[String: Any]] {
            root = [:]
            rawApps = apps
        } else {
            throw WorkspaceRepositoryInspectionError.unsupportedFormat
        }

        let repositoryName = (root["name"] as? String) ?? sourceURL?.host ?? "Repository"
        let values = rawApps.enumerated().compactMap { index, item -> WorkspaceRepositoryAppInspection? in
            let name = (item["name"] as? String) ?? (item["title"] as? String) ?? ""
            let identifier = (item["bundleIdentifier"] as? String) ?? (item["bundleID"] as? String) ?? (item["identifier"] as? String)
            let download = (item["downloadURL"] as? String ?? item["download"] as? String).flatMap { URL(string: $0) }
            let icon = (item["iconURL"] as? String ?? item["icon"] as? String).flatMap { URL(string: $0) }
            let version = item["version"] as? String
            let category = item["category"] as? String
            let bytes = (item["size"] as? NSNumber)?.uint64Value
            let id = identifier ?? download?.absoluteString ?? "(repositoryName)-(index)"
            return WorkspaceRepositoryAppInspection(id: id, name: name, bundleIdentifier: identifier, version: version, category: category, downloadURL: download, iconURL: icon, byteCount: bytes)
        }
        return WorkspaceRepositoryInspection(sourceURL: sourceURL, name: repositoryName, apps: values, inspectedAt: .now)
    }

    static func inspect(url: URL) async throws -> WorkspaceRepositoryInspection {
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { throw WorkspaceRepositoryInspectionError.requestFailed }
        return try inspect(data: data, sourceURL: url)
    }
}

struct WorkspaceInstallerFileInspection: Identifiable, Hashable {
    let id: String
    let url: URL
    let kind: String
    let byteCount: UInt64
    let modifiedAt: Date?
    let canInspect: Bool
}

struct WorkspaceInstalledGuestSummary: Identifiable, Hashable {
    let id: UUID
    let name: String
    let bundleIdentifier: String
    let version: String
    let state: VirtualAppStatus
}

@MainActor
struct WorkspaceInstallerInspector {
    static func files(in rootDirectory: URL) -> [WorkspaceInstallerFileInspection] {
        let manager = FileManager.default
        guard let urls = try? manager.contentsOfDirectory(at: rootDirectory, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey], options: [.skipsHiddenFiles]) else { return [] }
        return urls.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]) else { return nil }
            let ext = url.pathExtension.lowercased()
            let kind: String
            switch ext {
            case "ipa", "tipa", "zip": kind = "IPA archive"
            case "p12", "pfx": kind = "Signing certificate"
            case "mobileprovision", "provisionprofile": kind = "Provisioning profile"
            default: kind = "File"
            }
            return WorkspaceInstallerFileInspection(id: url.path, url: url, kind: kind, byteCount: UInt64(values.fileSize ?? 0), modifiedAt: values.contentModificationDate, canInspect: ["ipa", "tipa", "zip", "p12", "pfx", "mobileprovision", "provisionprofile"].contains(ext))
        }.sorted { $0.url.lastPathComponent.localizedCaseInsensitiveCompare($1.url.lastPathComponent) == .orderedAscending }
    }

    static func installedGuests(from store: WorkspaceStore) -> [WorkspaceInstalledGuestSummary] {
        store.installedApps.map { app in
            WorkspaceInstalledGuestSummary(id: app.id, name: app.displayName, bundleIdentifier: app.bundleIdentifier, version: app.version, state: app.status)
        }
    }
}

