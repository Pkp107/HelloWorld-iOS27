import Foundation
import Security
import SwiftUI
import UIKit

/// Workspace's developer environment. It owns project files in Workspace
/// Files/Projects and keeps remote build credentials in the Keychain.
enum WorkspaceDeveloperToolTab: Hashable {
    case studio
    case builds
    case github
    case inspector
    case network
}

struct WorkspaceDeveloperToolsView: View {
    @ObservedObject private var workspace: WorkspaceStore
    @StateObject private var github = WorkspaceGitHubModel()
    @State private var selectedTab: WorkspaceDeveloperToolTab

    init(store: WorkspaceStore, initialTab: WorkspaceDeveloperToolTab = .studio) {
        _workspace = ObservedObject(wrappedValue: store)
        _selectedTab = State(initialValue: initialTab)
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            WorkspaceDevStudioView(store: workspace, github: github)
                .tabItem { Label("Studio", systemImage: "hammer.fill") }
                .tag(WorkspaceDeveloperToolTab.studio)

            WorkspaceBuildsView(github: github)
                .tabItem { Label("Builds", systemImage: "play.circle.fill") }
                .tag(WorkspaceDeveloperToolTab.builds)

            WorkspaceGitHubManagerView(github: github)
                .tabItem { Label("GitHub", systemImage: "arrow.triangle.branch") }
                .tag(WorkspaceDeveloperToolTab.github)

            WorkspaceInspectorView(store: workspace)
                .tabItem { Label("Inspector", systemImage: "ladybug.fill") }
                .tag(WorkspaceDeveloperToolTab.inspector)

            WorkspaceNetworkServicesView(store: workspace)
                .tabItem { Label("Network", systemImage: "network") }
                .tag(WorkspaceDeveloperToolTab.network)
        }
        .tint(.indigo)
    }
}

// MARK: - Dev Studio

enum WorkspaceProjectTemplate: String, CaseIterable, Codable, Identifiable {
    case swift
    case c
    case cpp
    case java
    case dotnet
    case python
    case javascript
    case wasi

    var id: String { rawValue }

    var title: String {
        switch self {
        case .swift: return "Swift iOS"
        case .c: return "C"
        case .cpp: return "C++"
        case .java: return "Java"
        case .dotnet: return "C# / .NET"
        case .python: return "Python"
        case .javascript: return "TypeScript"
        case .wasi: return "WebAssembly / WASI"
        }
    }

    var symbol: String {
        switch self {
        case .swift: return "swift"
        case .c, .cpp: return "chevron.left.forwardslash.chevron.right"
        case .java: return "cup.and.saucer.fill"
        case .dotnet: return "square.stack.3d.forward.dottedline"
        case .python: return "function"
        case .javascript: return "curlybraces"
        case .wasi: return "shippingbox.fill"
        }
    }

    var sourceFileName: String {
        switch self {
        case .swift: return "main.swift"
        case .c: return "main.c"
        case .cpp: return "main.cpp"
        case .java: return "Main.java"
        case .dotnet: return "Program.cs"
        case .python: return "main.py"
        case .javascript: return "index.ts"
        case .wasi: return "main.c"
        }
    }

    var starterSource: String {
        switch self {
        case .swift:
            return "import Foundation\n\nprint(\"Hello from Workspace\")\n"
        case .c, .wasi:
            return "#include <stdio.h>\n\nint main(void) {\n    puts(\"Hello from Workspace\");\n    return 0;\n}\n"
        case .cpp:
            return "#include <iostream>\n\nint main() {\n    std::cout << \"Hello from Workspace\\n\";\n    return 0;\n}\n"
        case .java:
            return "public final class Main {\n    public static void main(String[] args) {\n        System.out.println(\"Hello from Workspace\");\n    }\n}\n"
        case .dotnet:
            return "Console.WriteLine(\"Hello from Workspace\");\n"
        case .python:
            return "print(\"Hello from Workspace\")\n"
        case .javascript:
            return "console.log(\"Hello from Workspace\");\n"
        }
    }

    var workflowLanguage: String {
        switch self {
        case .swift: return "swift"
        case .c, .wasi: return "c"
        case .cpp: return "cpp"
        case .java: return "java"
        case .dotnet: return "csharp"
        case .python: return "python"
        case .javascript: return "javascript"
        }
    }
}

enum WorkspaceBuildTarget: String, CaseIterable, Codable, Identifiable {
    case wasm
    case windowsEXE
    case iosSimulator
    case iphoneIPA

    var id: String { rawValue }

    var title: String {
        switch self {
        case .wasm: return "WebAssembly"
        case .windowsEXE: return "Windows EXE"
        case .iosSimulator: return "iOS Simulator"
        case .iphoneIPA: return "iPhone IPA"
        }
    }

    var symbol: String {
        switch self {
        case .wasm: return "shippingbox.fill"
        case .windowsEXE: return "desktopcomputer"
        case .iosSimulator: return "iphone.gen3"
        case .iphoneIPA: return "iphone.and.arrow.forward"
        }
    }

    var workflowValue: String {
        switch self {
        case .wasm: return "wasm"
        case .windowsEXE: return "windows-exe"
        case .iosSimulator: return "ios-simulator"
        case .iphoneIPA: return "ios-ipa"
        }
    }
}

struct WorkspaceDeveloperProject: Codable, Identifiable, Hashable {
    let id: UUID
    var name: String
    var template: WorkspaceProjectTemplate
    var createdAt: Date
    var updatedAt: Date

    var sourceFileName: String { template.sourceFileName }
}

@MainActor
final class WorkspaceProjectStore: ObservableObject {
    @Published private(set) var projects: [WorkspaceDeveloperProject] = []
    @Published var errorMessage: String?

    private let rootURL: URL
    private let fileManager = FileManager.default

    init(workspaceRoot: URL) {
        rootURL = workspaceRoot.appendingPathComponent("Projects", isDirectory: true)
        load()
    }

    func source(for project: WorkspaceDeveloperProject) -> String {
        let url = sourceURL(for: project)
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    func create(name: String, template: WorkspaceProjectTemplate) -> WorkspaceDeveloperProject? {
        let cleanedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanedName.isEmpty else {
            errorMessage = "Enter a project name."
            return nil
        }
        let project = WorkspaceDeveloperProject(
            id: UUID(),
            name: cleanedName,
            template: template,
            createdAt: .now,
            updatedAt: .now
        )
        do {
            let directory = projectDirectory(for: project)
            let sources = directory.appendingPathComponent("Sources", isDirectory: true)
            try fileManager.createDirectory(at: sources, withIntermediateDirectories: true)
            try template.starterSource.write(to: sourceURL(for: project), atomically: true, encoding: .utf8)
            let readme = "# \(cleanedName)\n\nCreated in Workspace Dev Studio.\n"
            try readme.write(to: directory.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
            projects.append(project)
            projects.sort { $0.updatedAt > $1.updatedAt }
            persist()
            return project
        } catch {
            errorMessage = "Could not create the project: \(error.localizedDescription)"
            return nil
        }
    }

    func save(source: String, for project: WorkspaceDeveloperProject) {
        guard let index = projects.firstIndex(where: { $0.id == project.id }) else { return }
        do {
            try source.write(to: sourceURL(for: project), atomically: true, encoding: .utf8)
            projects[index].updatedAt = .now
            projects.sort { $0.updatedAt > $1.updatedAt }
            persist()
        } catch {
            errorMessage = "Could not save the source file: \(error.localizedDescription)"
        }
    }

    func delete(_ project: WorkspaceDeveloperProject) {
        do {
            try fileManager.removeItem(at: projectDirectory(for: project))
            projects.removeAll { $0.id == project.id }
            persist()
        } catch {
            errorMessage = "Could not remove \(project.name): \(error.localizedDescription)"
        }
    }

    func projectURL(_ project: WorkspaceDeveloperProject) -> URL {
        projectDirectory(for: project)
    }

    private var manifestURL: URL {
        rootURL.appendingPathComponent(".workspace-projects.json", isDirectory: false)
    }

    private func projectDirectory(for project: WorkspaceDeveloperProject) -> URL {
        rootURL.appendingPathComponent(project.id.uuidString, isDirectory: true)
    }

    private func sourceURL(for project: WorkspaceDeveloperProject) -> URL {
        projectDirectory(for: project)
            .appendingPathComponent("Sources", isDirectory: true)
            .appendingPathComponent(project.sourceFileName, isDirectory: false)
    }

    private func load() {
        do {
            try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
            guard fileManager.fileExists(atPath: manifestURL.path) else { return }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            projects = try decoder.decode([WorkspaceDeveloperProject].self, from: Data(contentsOf: manifestURL))
            projects.sort { $0.updatedAt > $1.updatedAt }
        } catch {
            errorMessage = "Could not load projects: \(error.localizedDescription)"
        }
    }

    private func persist() {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(projects)
            try data.write(to: manifestURL, options: .atomic)
        } catch {
            errorMessage = "Could not save project metadata: \(error.localizedDescription)"
        }
    }
}

struct WorkspaceDevStudioView: View {
    @ObservedObject private var github: WorkspaceGitHubModel
    @StateObject private var projects: WorkspaceProjectStore
    @State private var selectedProject: WorkspaceDeveloperProject?
    @State private var isPresentingNewProject = false

    init(store: WorkspaceStore, github: WorkspaceGitHubModel) {
        _github = ObservedObject(wrappedValue: github)
        _projects = StateObject(wrappedValue: WorkspaceProjectStore(workspaceRoot: store.workspaceFilesDirectory))
    }

    var body: some View {
        NavigationStack {
            Group {
                if projects.projects.isEmpty {
                    ContentUnavailableView(
                        "No projects",
                        systemImage: "hammer",
                        description: Text("Create a project to edit its source files and send builds to GitHub Actions.")
                    )
                } else {
                    List {
                        Section("Projects") {
                            ForEach(projects.projects) { project in
                                Button {
                                    selectedProject = project
                                } label: {
                                    HStack(spacing: 12) {
                                        Image(systemName: project.template.symbol)
                                            .foregroundStyle(.white)
                                            .frame(width: 42, height: 42)
                                            .background(.indigo, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text(project.name).font(.body.weight(.semibold))
                                            Text("\(project.template.title) · \(project.sourceFileName)")
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                        Spacer()
                                        Image(systemName: "chevron.right")
                                            .font(.caption.weight(.semibold))
                                            .foregroundStyle(.tertiary)
                                    }
                                }
                                .buttonStyle(.plain)
                            }
                            .onDelete { offsets in
                                offsets.compactMap { projects.projects.indices.contains($0) ? projects.projects[$0] : nil }
                                    .forEach(projects.delete)
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle("Dev Studio")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { isPresentingNewProject = true } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("Create project")
                }
            }
            .sheet(isPresented: $isPresentingNewProject) {
                WorkspaceNewProjectView(projects: projects) { project in
                    selectedProject = project
                }
            }
            .navigationDestination(item: $selectedProject) { project in
                WorkspaceProjectEditorView(project: project, projects: projects, github: github)
            }
            .alert("Dev Studio", isPresented: Binding(
                get: { projects.errorMessage != nil },
                set: { if !$0 { projects.errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) { projects.errorMessage = nil }
            } message: {
                Text(projects.errorMessage ?? "")
            }
        }
    }
}

private struct WorkspaceNewProjectView: View {
    @ObservedObject var projects: WorkspaceProjectStore
    let onCreated: (WorkspaceDeveloperProject) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var template = WorkspaceProjectTemplate.swift

    var body: some View {
        NavigationStack {
            Form {
                Section("Project") {
                    TextField("Name", text: $name)
                    Picker("Template", selection: $template) {
                        ForEach(WorkspaceProjectTemplate.allCases) { template in
                            Label(template.title, systemImage: template.symbol).tag(template)
                        }
                    }
                }
                Section {
                    Text("Source files are kept in Workspace Files / Projects and can be committed by your configured GitHub workflow.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("New project")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        guard let project = projects.create(name: name, template: template) else { return }
                        dismiss()
                        onCreated(project)
                    }
                }
            }
        }
    }
}

private struct WorkspaceProjectEditorView: View {
    let project: WorkspaceDeveloperProject
    @ObservedObject var projects: WorkspaceProjectStore
    @ObservedObject var github: WorkspaceGitHubModel
    @State private var source = ""
    @State private var target = WorkspaceBuildTarget.iphoneIPA
    @State private var isDispatching = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: project.template.symbol)
                    .foregroundStyle(.tint)
                Text(project.sourceFileName)
                    .font(.footnote.monospaced())
                    .lineLimit(1)
                Spacer()
                Text(projects.projectURL(project).path.replacingOccurrences(of: FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].path, with: "Documents"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.bar)

            TextEditor(text: $source)
                .font(.system(.body, design: .monospaced))
                .padding(.horizontal, 6)
                .accessibilityLabel("Source code")
        }
        .navigationTitle(project.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Menu {
                    Picker("Build target", selection: $target) {
                        ForEach(WorkspaceBuildTarget.allCases) { target in
                            Label(target.title, systemImage: target.symbol).tag(target)
                        }
                    }
                } label: {
                    Image(systemName: target.symbol)
                }
                .accessibilityLabel("Build target")

                Button {
                    projects.save(source: source, for: project)
                } label: {
                    Image(systemName: "square.and.arrow.down")
                }
                .accessibilityLabel("Save source")
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            HStack(spacing: 12) {
                Button("Save") {
                    projects.save(source: source, for: project)
                }
                .buttonStyle(.bordered)

                Button {
                    projects.save(source: source, for: project)
                    isDispatching = true
                    Task {
                        guard let remotePath = await github.publish(project: project, source: source) else {
                            isDispatching = false
                            return
                        }
                        await github.dispatch(target: target, project: project, entryPath: remotePath)
                        isDispatching = false
                    }
                } label: {
                    Label(isDispatching ? "Starting build" : "Build \(target.title)", systemImage: "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(isDispatching)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.bar)
        }
        .onAppear { source = projects.source(for: project) }
    }
}

// MARK: - GitHub Actions

struct WorkspaceGitHubWorkflowRun: Decodable, Identifiable, Hashable {
    let id: Int
    let name: String?
    let displayTitle: String?
    let status: String?
    let conclusion: String?
    let event: String?
    let htmlURL: URL?
    let createdAt: Date?
    let updatedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id, name, status, conclusion, event
        case displayTitle = "display_title"
        case htmlURL = "html_url"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    var title: String { displayTitle ?? name ?? "Workflow run #\(id)" }
    var resultLabel: String { conclusion ?? status ?? "Queued" }
    var isSuccessful: Bool { conclusion == "success" }
}

struct WorkspaceGitHubRepository: Decodable, Identifiable, Hashable {
    let id: Int
    let fullName: String
    let privateRepository: Bool
    let defaultBranch: String
    let htmlURL: URL?
    let updatedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id
        case fullName = "full_name"
        case privateRepository = "private"
        case defaultBranch = "default_branch"
        case htmlURL = "html_url"
        case updatedAt = "updated_at"
    }
}

private struct WorkspaceGitHubBranch: Decodable {
    let name: String
}

private struct WorkspaceGitHubRunsResponse: Decodable {
    let workflowRuns: [WorkspaceGitHubWorkflowRun]

    enum CodingKeys: String, CodingKey {
        case workflowRuns = "workflow_runs"
    }
}

private struct WorkspaceGitHubErrorResponse: Decodable {
    let message: String?
}

private struct WorkspaceGitHubContentResponse: Decodable {
    let sha: String
}

struct WorkspaceGitHubConfiguration: Codable, Equatable {
    var repository: String = ""
    var workflow: String = "workspace-build.yml"
    var branch: String = "main"
    var workflowInputs: String = ""
}

@MainActor
final class WorkspaceGitHubModel: ObservableObject {
    @Published var repository: String
    @Published var workflow: String
    @Published var branch: String
    @Published var workflowInputs: String
    @Published var token: String
    @Published private(set) var runs: [WorkspaceGitHubWorkflowRun] = []
    @Published private(set) var repositories: [WorkspaceGitHubRepository] = []
    @Published private(set) var branches: [String] = []
    @Published private(set) var isLoading = false
    @Published private(set) var statusMessage: String?

    private static let configurationKey = "workspace.github.configuration.v1"

    init() {
        let configuration: WorkspaceGitHubConfiguration
        if let data = UserDefaults.standard.data(forKey: Self.configurationKey),
           let saved = try? JSONDecoder().decode(WorkspaceGitHubConfiguration.self, from: data) {
            configuration = saved
        } else {
            configuration = WorkspaceGitHubConfiguration()
        }
        repository = configuration.repository
        workflow = configuration.workflow.isEmpty ? "workspace-build.yml" : configuration.workflow
        branch = configuration.branch
        workflowInputs = configuration.workflowInputs
        token = WorkspaceGitHubCredentialStore.load() ?? ""
    }

    var isConfigured: Bool {
        !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && repositoryParts != nil && !workflow.isEmpty
    }

    var repositoryParts: (owner: String, name: String)? {
        let pieces = repository.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
        guard pieces.count == 2, !pieces[0].isEmpty, !pieces[1].isEmpty else { return nil }
        return (pieces[0], pieces[1])
    }

    func saveConfiguration() {
        let configuration = WorkspaceGitHubConfiguration(
            repository: repository.trimmingCharacters(in: .whitespacesAndNewlines),
            workflow: workflow.trimmingCharacters(in: .whitespacesAndNewlines),
            branch: branch.trimmingCharacters(in: .whitespacesAndNewlines),
            workflowInputs: workflowInputs
        )
        guard let data = try? JSONEncoder().encode(configuration) else { return }
        UserDefaults.standard.set(data, forKey: Self.configurationKey)
        do {
            try WorkspaceGitHubCredentialStore.save(token.trimmingCharacters(in: .whitespacesAndNewlines))
            statusMessage = "GitHub configuration saved."
        } catch {
            statusMessage = "Could not save the GitHub token: \(error.localizedDescription)"
        }
    }

    func loadRepositories() async {
        guard prepareRequest(requireRepository: false) else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let data = try await request(path: ["user", "repos"], query: ["per_page": "100", "sort": "updated"])
            repositories = try Self.decoder.decode([WorkspaceGitHubRepository].self, from: data)
            statusMessage = "Loaded \(repositories.count) repositories."
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func loadBranches() async {
        guard let parts = repositoryParts, prepareRequest() else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let data = try await request(path: ["repos", parts.owner, parts.name, "branches"], query: ["per_page": "100"])
            branches = try Self.decoder.decode([WorkspaceGitHubBranch].self, from: data).map(\.name)
            if branch.isEmpty { branch = branches.first ?? "main" }
            statusMessage = "Loaded \(branches.count) branches."
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func loadWorkflowRuns() async {
        guard let parts = repositoryParts, prepareRequest() else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let data = try await request(
                path: ["repos", parts.owner, parts.name, "actions", "workflows", workflow, "runs"],
                query: ["per_page": "20"]
            )
            runs = try Self.decoder.decode(WorkspaceGitHubRunsResponse.self, from: data).workflowRuns
            statusMessage = "Updated workflow runs."
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func publish(project: WorkspaceDeveloperProject, source: String) async -> String? {
        guard let parts = repositoryParts, prepareRequest() else { return nil }
        isLoading = true
        defer { isLoading = false }
        let remotePath = "WorkspaceProjects/\(project.id.uuidString)/Sources/\(project.sourceFileName)"
        let path = ["repos", parts.owner, parts.name, "contents"] + remotePath.split(separator: "/").map(String.init)
        do {
            var payload: [String: Any] = [
                "message": "Update \(project.name) from Workspace",
                "content": Data(source.utf8).base64EncodedString(),
                "branch": branch.isEmpty ? "main" : branch
            ]
            if let existing = try? await request(
                path: path,
                query: ["ref": branch.isEmpty ? "main" : branch]
            ),
               let current = try? Self.decoder.decode(WorkspaceGitHubContentResponse.self, from: existing) {
                payload["sha"] = current.sha
            }
            _ = try await request(
                path: path,
                method: "PUT",
                body: try JSONSerialization.data(withJSONObject: payload)
            )
            statusMessage = "Uploaded \(project.sourceFileName) to GitHub."
            return remotePath
        } catch {
            statusMessage = error.localizedDescription
            return nil
        }
    }

    func dispatch(target: WorkspaceBuildTarget, project: WorkspaceDeveloperProject?, entryPath: String? = nil) async {
        guard let parts = repositoryParts, prepareRequest() else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            var inputs = parseWorkflowInputs(workflowInputs)
            inputs["target"] = target.workflowValue
            if let project {
                inputs["language"] = project.template.workflowLanguage
                inputs["entry_path"] = entryPath ?? "Sources/\(project.sourceFileName)"
            } else {
                inputs["language"] = inputs["language"] ?? "swift"
                inputs["entry_path"] = inputs["entry_path"] ?? "Sources/main.swift"
            }
            let body: [String: Any] = ["ref": branch.isEmpty ? "main" : branch, "inputs": inputs]
            _ = try await request(
                path: ["repos", parts.owner, parts.name, "actions", "workflows", workflow, "dispatches"],
                method: "POST",
                body: try JSONSerialization.data(withJSONObject: body)
            )
            statusMessage = "Build request sent for \(target.title)."
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            await loadWorkflowRuns()
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func choose(repository selected: WorkspaceGitHubRepository) {
        repository = selected.fullName
        branch = selected.defaultBranch
        branches = []
        runs = []
        saveConfiguration()
    }

    private func prepareRequest(requireRepository: Bool = true) -> Bool {
        guard !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            statusMessage = "Add a GitHub token before connecting."
            return false
        }
        guard !requireRepository || repositoryParts != nil else {
            statusMessage = "Enter a repository as owner/repository."
            return false
        }
        return true
    }

    private func request(
        path: [String],
        query: [String: String] = [:],
        method: String = "GET",
        body: Data? = nil
    ) async throws -> Data {
        guard var components = URLComponents(string: "https://api.github.com") else {
            throw WorkspaceGitHubError.invalidEndpoint
        }
        components.path = "/" + path.map { $0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? $0 }.joined(separator: "/")
        if !query.isEmpty {
            components.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        guard let url = components.url else { throw WorkspaceGitHubError.invalidEndpoint }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 30
        request.setValue("Bearer \(token.trimmingCharacters(in: .whitespacesAndNewlines))", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("Workspace-iOS", forHTTPHeaderField: "User-Agent")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw WorkspaceGitHubError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            let message = (try? Self.decoder.decode(WorkspaceGitHubErrorResponse.self, from: data).message) ?? "HTTP \(http.statusCode)"
            throw WorkspaceGitHubError.api(message)
        }
        return data
    }

    private func parseWorkflowInputs(_ value: String) -> [String: String] {
        value.split(whereSeparator: \.isNewline).reduce(into: [:]) { result, line in
            let pair = line.split(separator: "=", maxSplits: 1).map(String.init)
            guard pair.count == 2 else { return }
            let key = pair[0].trimmingCharacters(in: .whitespacesAndNewlines)
            let value = pair[1].trimmingCharacters(in: .whitespacesAndNewlines)
            if !key.isEmpty { result[key] = value }
        }
    }

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

private enum WorkspaceGitHubError: LocalizedError {
    case invalidEndpoint
    case invalidResponse
    case api(String)

    var errorDescription: String? {
        switch self {
        case .invalidEndpoint: return "Could not create the GitHub API request."
        case .invalidResponse: return "GitHub returned an invalid response."
        case .api(let message): return "GitHub: \(message)"
        }
    }
}

private enum WorkspaceGitHubCredentialStore {
    private static let service = "com.pkp107.workspace.github"
    private static let account = "github-token"

    static func load() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func save(_ token: String) throws {
        if token.isEmpty {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account
            ]
            SecItemDelete(query as CFDictionary)
            return
        }
        let data = Data(token.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let update: [String: Any] = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(updateStatus))
        }
        let create: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let createStatus = SecItemAdd(create as CFDictionary, nil)
        guard createStatus == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(createStatus))
        }
    }
}

struct WorkspaceBuildsView: View {
    @ObservedObject var github: WorkspaceGitHubModel
    @State private var target = WorkspaceBuildTarget.iphoneIPA
    @State private var isDispatching = false

    var body: some View {
        NavigationStack {
            List {
                Section("GitHub Actions") {
                    TextField("Repository", text: $github.repository, prompt: Text("owner/repository"))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("Workflow", text: $github.workflow, prompt: Text("workspace-build.yml"))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("Branch", text: $github.branch, prompt: Text("main"))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("GitHub token", text: $github.token)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextEditor(text: $github.workflowInputs)
                        .font(.footnote.monospaced())
                        .frame(minHeight: 72)
                        .overlay(alignment: .topLeading) {
                            if github.workflowInputs.isEmpty {
                                Text("Optional workflow inputs, one key=value per line")
                                    .font(.footnote)
                                    .foregroundStyle(.tertiary)
                                    .padding(.top, 8)
                                    .padding(.leading, 5)
                                    .allowsHitTesting(false)
                            }
                        }
                    Button("Save GitHub configuration") { github.saveConfiguration() }
                }

                Section("Start a build") {
                    Picker("Target", selection: $target) {
                        ForEach(WorkspaceBuildTarget.allCases) { target in
                            Label(target.title, systemImage: target.symbol).tag(target)
                        }
                    }
                    Button {
                        isDispatching = true
                        github.saveConfiguration()
                        Task {
                            await github.dispatch(target: target, project: nil)
                            isDispatching = false
                        }
                    } label: {
                        Label(isDispatching ? "Starting build" : "Build \(target.title)", systemImage: "play.fill")
                    }
                    .disabled(isDispatching)
                }

                Section("Recent runs") {
                    if github.runs.isEmpty {
                        ContentUnavailableView("No runs loaded", systemImage: "clock", description: Text("Refresh after configuring a repository and workflow."))
                    } else {
                        ForEach(github.runs) { run in
                            WorkspaceWorkflowRunRow(run: run)
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Builds")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await github.loadWorkflowRuns() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(github.isLoading)
                    .accessibilityLabel("Refresh workflow runs")
                }
            }
            .task {
                if github.isConfigured { await github.loadWorkflowRuns() }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if let status = github.statusMessage {
                    Text(status)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 9)
                        .background(.bar)
                }
            }
        }
    }
}

private struct WorkspaceWorkflowRunRow: View {
    let run: WorkspaceGitHubWorkflowRun

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: run.isSuccessful ? "checkmark.circle.fill" : "clock.fill")
                .foregroundStyle(run.isSuccessful ? .green : .orange)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 3) {
                Text(run.title).font(.body.weight(.medium)).lineLimit(1)
                Text(run.resultLabel.capitalized)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let url = run.htmlURL {
                Link(destination: url) {
                    Image(systemName: "arrow.up.right.square")
                }
                .accessibilityLabel("Open workflow run")
            }
        }
    }
}

struct WorkspaceGitHubManagerView: View {
    @ObservedObject var github: WorkspaceGitHubModel

    var body: some View {
        NavigationStack {
            List {
                Section("Current repository") {
                    LabeledContent("Repository", value: github.repository.isEmpty ? "Not selected" : github.repository)
                    LabeledContent("Branch", value: github.branch.isEmpty ? "Not selected" : github.branch)
                    Button("Load branches") { Task { await github.loadBranches() } }
                        .disabled(github.isLoading)
                    if !github.branches.isEmpty {
                        Picker("Active branch", selection: $github.branch) {
                            ForEach(github.branches, id: \.self) { branch in
                                Text(branch).tag(branch)
                            }
                        }
                        .onChange(of: github.branch) { _, _ in github.saveConfiguration() }
                    }
                }

                Section("Repositories") {
                    if github.repositories.isEmpty {
                        ContentUnavailableView("No repositories loaded", systemImage: "arrow.triangle.branch", description: Text("Connect a GitHub token with repository access, then refresh."))
                    } else {
                        ForEach(github.repositories) { repository in
                            Button {
                                github.choose(repository: repository)
                                Task { await github.loadBranches() }
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: repository.privateRepository ? "lock.fill" : "book.closed.fill")
                                        .foregroundStyle(.white)
                                        .frame(width: 38, height: 38)
                                        .background(.blue, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(repository.fullName).font(.body.weight(.medium))
                                        Text(repository.defaultBranch)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    if github.repository == repository.fullName {
                                        Image(systemName: "checkmark")
                                            .foregroundStyle(.tint)
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("GitHub")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        github.saveConfiguration()
                        Task { await github.loadRepositories() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(github.isLoading)
                    .accessibilityLabel("Refresh repositories")
                }
            }
            .task {
                if github.isConfigured { await github.loadRepositories() }
            }
        }
    }
}

// MARK: - Diagnostics and Frida preparation

struct WorkspaceDiagnosticEntry: Codable, Identifiable, Hashable {
    enum Source: String, Codable, CaseIterable {
        case host
        case frida

        var title: String { rawValue == "host" ? "Workspace" : "Frida" }
        var symbol: String { rawValue == "host" ? "terminal.fill" : "ant.fill" }
    }

    let id: UUID
    let date: Date
    let source: Source
    let message: String
}

@MainActor
final class WorkspaceDiagnosticStore: ObservableObject {
    @Published private(set) var entries: [WorkspaceDiagnosticEntry] = []
    @Published var errorMessage: String?

    private let rootURL: URL
    private let fileManager = FileManager.default

    init(workspaceRoot: URL) {
        rootURL = workspaceRoot.appendingPathComponent("Diagnostics", isDirectory: true)
        reload()
    }

    func reload() {
        do {
            try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
            guard fileManager.fileExists(atPath: logURL.path) else {
                entries = []
                return
            }
            let data = try Data(contentsOf: logURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            entries = try decoder.decode([WorkspaceDiagnosticEntry].self, from: data)
                .sorted { $0.date > $1.date }
        } catch {
            errorMessage = "Could not read diagnostics: \(error.localizedDescription)"
        }
    }

    func append(_ message: String, source: WorkspaceDiagnosticEntry.Source = .host) {
        let cleaned = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }
        entries.insert(WorkspaceDiagnosticEntry(id: UUID(), date: .now, source: source, message: cleaned), at: 0)
        if entries.count > 300 { entries = Array(entries.prefix(300)) }
        persist()
    }

    func clear() {
        entries = []
        persist()
    }

    func prepareFridaGadget(for ipa: URL) {
        do {
            try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
            let plan = WorkspaceFridaPreparationPlan(
                createdAt: .now,
                sourceIPAPath: ipa.path,
                steps: [
                    "Copy the guest IPA into Workspace Files/IPAs.",
                    "Add the matching Frida Gadget framework to the guest app bundle.",
                    "Configure Gadget to listen only on the selected local endpoint.",
                    "Re-sign the modified IPA with the Installer certificate and provisioning profile.",
                    "Install the re-signed package through LiveContainer, then connect from Inspector."
                ]
            )
            let name = ipa.deletingPathExtension().lastPathComponent + "-frida-plan.json"
            let destination = rootURL.appendingPathComponent(name, isDirectory: false)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(plan).write(to: destination, options: .atomic)
            append("Created Frida Gadget preparation plan for \(ipa.lastPathComponent).", source: .frida)
        } catch {
            errorMessage = "Could not create the Frida plan: \(error.localizedDescription)"
        }
    }

    private var logURL: URL { rootURL.appendingPathComponent("workspace-diagnostics.json", isDirectory: false) }

    private func persist() {
        do {
            try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(entries).write(to: logURL, options: .atomic)
        } catch {
            errorMessage = "Could not save diagnostics: \(error.localizedDescription)"
        }
    }
}

private struct WorkspaceFridaPreparationPlan: Codable {
    let createdAt: Date
    let sourceIPAPath: String
    let steps: [String]
}

struct WorkspaceInspectorView: View {
    @ObservedObject private var workspace: WorkspaceStore
    @StateObject private var diagnostics: WorkspaceDiagnosticStore
    @State private var note = ""
    @State private var selectedIPA: URL?
    @State private var isShowingIPAs = false

    init(store: WorkspaceStore) {
        _workspace = ObservedObject(wrappedValue: store)
        _diagnostics = StateObject(wrappedValue: WorkspaceDiagnosticStore(workspaceRoot: store.workspaceFilesDirectory))
    }

    private var ipaFiles: [URL] {
        workspace.workspaceFiles().filter { ["ipa", "tipa"].contains($0.pathExtension.lowercased()) }
    }

    var body: some View {
        NavigationStack {
            List {
                Section("Host log") {
                    HStack(spacing: 10) {
                        TextField("Add diagnostic message", text: $note)
                        Button {
                            diagnostics.append(note)
                            note = ""
                        } label: {
                            Image(systemName: "plus.circle.fill")
                        }
                        .disabled(note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }

                Section("Frida Gadget preparation") {
                    Text("Prepare only guest apps you install through LiveContainer. Workspace records a re-signing plan in Diagnostics; the modified IPA must still be signed before it can run.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Button("Choose guest IPA") { isShowingIPAs = true }
                    if let selectedIPA {
                        LabeledContent("Selected", value: selectedIPA.lastPathComponent)
                        Button("Create preparation plan") { diagnostics.prepareFridaGadget(for: selectedIPA) }
                    }
                }

                Section("Recent events") {
                    if diagnostics.entries.isEmpty {
                        ContentUnavailableView("No diagnostic events", systemImage: "terminal", description: Text("Workspace and supported guest integrations can write events here."))
                    } else {
                        ForEach(diagnostics.entries) { entry in
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: entry.source.symbol)
                                    .foregroundStyle(entry.source == .host ? .indigo : .orange)
                                    .frame(width: 22)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(entry.message).font(.footnote)
                                    Text(entry.date.formatted(date: .abbreviated, time: .standard))
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Inspector")
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button { diagnostics.reload() } label: { Image(systemName: "arrow.clockwise") }
                    Button("Clear", role: .destructive) { diagnostics.clear() }
                }
            }
            .confirmationDialog("Choose guest IPA", isPresented: $isShowingIPAs) {
                ForEach(ipaFiles, id: \.path) { ipa in
                    Button(ipa.lastPathComponent) { selectedIPA = ipa }
                }
                Button("Cancel", role: .cancel) {}
            }
            .alert("Inspector", isPresented: Binding(
                get: { diagnostics.errorMessage != nil },
                set: { if !$0 { diagnostics.errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) { diagnostics.errorMessage = nil }
            } message: {
                Text(diagnostics.errorMessage ?? "")
            }
        }
    }
}

// MARK: - Network and MCP configuration

struct WorkspaceNetworkConfiguration: Codable, Equatable {
    var mcpEnabled: Bool = false
    var advertiseOnLAN: Bool = false
}

@MainActor
final class WorkspaceNetworkConfigurationStore: ObservableObject {
    @Published var configuration: WorkspaceNetworkConfiguration {
        didSet { persist() }
    }

    private static let configurationKey = "workspace.network.configuration.v1"

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.configurationKey),
           let saved = try? JSONDecoder().decode(WorkspaceNetworkConfiguration.self, from: data) {
            configuration = saved
        } else {
            configuration = WorkspaceNetworkConfiguration()
        }
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(configuration) else { return }
        UserDefaults.standard.set(data, forKey: Self.configurationKey)
    }
}

struct WorkspaceNetworkServicesView: View {
    @ObservedObject private var workspace: WorkspaceStore
    @ObservedObject private var bridge: WorkspaceMCPServer
    @StateObject private var settings = WorkspaceNetworkConfigurationStore()

    init(store: WorkspaceStore) {
        _workspace = ObservedObject(wrappedValue: store)
        _bridge = ObservedObject(wrappedValue: WorkspaceMCPServer.shared)
    }

    private var mcpEnabled: Binding<Bool> {
        Binding(
            get: { bridge.isRunning },
            set: { enabled in
                settings.configuration.mcpEnabled = enabled
                if enabled {
                    bridge.start(
                        rootDirectory: workspace.workspaceFilesDirectory,
                        advertiseOnLAN: settings.configuration.advertiseOnLAN
                    )
                } else {
                    bridge.stop()
                }
            }
        )
    }

    private var advertiseOnLAN: Binding<Bool> {
        Binding(
            get: { settings.configuration.advertiseOnLAN },
            set: { value in
                settings.configuration.advertiseOnLAN = value
                guard bridge.isRunning else { return }
                bridge.start(
                    rootDirectory: workspace.workspaceFilesDirectory,
                    advertiseOnLAN: value
                )
            }
        )
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Local services") {
                    Toggle("Enable MCP sandbox bridge", isOn: mcpEnabled)
                    Toggle("Advertise on local network", isOn: advertiseOnLAN)
                        .disabled(!bridge.isRunning)
                    LabeledContent("Status", value: bridge.statusMessage)
                }

                Section("MCP endpoint") {
                    LabeledContent("Address", value: bridge.endpoint?.absoluteString ?? "Start the bridge to create an endpoint")
                    LabeledContent("Requests", value: String(bridge.requestCount))
                    LabeledContent("Access token", value: bridge.accessToken)
                        .font(.footnote.monospaced())
                    Button("Copy access token") {
                        UIPasteboard.general.string = bridge.accessToken
                    }
                    Button("Generate new access token") { bridge.rotateAccessToken() }
                    Text("Use the access token with every MCP request. The bridge can expose only Workspace Files operations such as listing, reading, copying, moving, and deleting files.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("Allowed operations") {
                    Label("List Workspace Files", systemImage: "list.bullet")
                    Label("Read and write project files", systemImage: "doc.text")
                    Label("Copy, move, and delete sandbox files", systemImage: "folder.badge.gearshape")
                }
            }
            .navigationTitle("Network Services")
            .onAppear {
                if settings.configuration.mcpEnabled, !bridge.isRunning {
                    bridge.start(
                        rootDirectory: workspace.workspaceFilesDirectory,
                        advertiseOnLAN: settings.configuration.advertiseOnLAN
                    )
                }
            }
        }
    }
}

struct WorkspaceRemoteDesktopView: View {
    @ObservedObject var store: WorkspaceStore
    let onOpen: (VirtualApp) -> Void

    private var moonlight: VirtualApp? {
        store.liveContainerApps.first {
            $0.displayName.localizedCaseInsensitiveContains("moonlight") ||
            $0.bundleIdentifier.localizedCaseInsensitiveContains("moonlight")
        }
    }

    private var installer: VirtualApp? {
        store.homeApps.first { $0.systemApp == .installer }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 14) {
                        Image(systemName: "rectangle.on.rectangle")
                            .font(.title2.weight(.semibold))
                            .foregroundStyle(.white)
                            .frame(width: 52, height: 52)
                            .background(.indigo, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Moonlight")
                                .font(.title3.weight(.bold))
                            Text("Launch a LiveContainer-managed remote desktop client")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 6)
                }
                .listRowBackground(Color.clear)

                if let moonlight {
                    Section("Installed client") {
                        LabeledContent("App", value: moonlight.displayName)
                        LabeledContent("Version", value: moonlight.version)
                        Button {
                            onOpen(moonlight)
                        } label: {
                            Label("Open Moonlight", systemImage: "play.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                    }
                } else {
                    ContentUnavailableView(
                        "Moonlight is not installed",
                        systemImage: "rectangle.on.rectangle",
                        description: Text("Install a Moonlight IPA through Installer and choose LiveContainer. This launcher will detect and open it here."))
                    if let installer {
                        Button {
                            onOpen(installer)
                        } label: {
                            Label("Open Installer", systemImage: "bag.fill")
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Remote Desktop")
        }
    }
}
