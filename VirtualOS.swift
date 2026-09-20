import Foundation
import SwiftUI
import UniformTypeIdentifiers

enum VirtualAppStatus: String, Codable, CaseIterable {
    case builtIn
    case imported
    case ready
    case unsupported

    var label: String {
        switch self {
        case .builtIn: return "System app"
        case .imported: return "Imported IPA"
        case .ready: return "Ready"
        case .unsupported: return "Runtime unavailable"
        }
    }
}

enum RuntimeSessionState: String, Codable {
    case running
    case suspended
}

struct VirtualApp: Identifiable, Codable, Hashable {
    var id: UUID
    var displayName: String
    var bundleIdentifier: String
    var version: String
    var iconSymbol: String
    var iconColor: String
    var category: String
    var ipaFileName: String?
    var isBuiltIn: Bool
    var isPinned: Bool
    var folderID: UUID?
    var status: VirtualAppStatus
    var addedAt: Date
    var lastOpened: Date?
}

struct VirtualFolder: Identifiable, Codable, Hashable {
    var id: UUID
    var name: String
    var symbol: String
}

struct RuntimeSession: Identifiable, Codable, Hashable {
    var id: UUID { appID }
    var appID: UUID
    var state: RuntimeSessionState
    var lastUsed: Date
}

struct WorkspaceSettings: Codable, Equatable {
    var showAppLabels = true
    var gridColumns = 4
    var confirmRemoval = true
    var reduceShellMotion = false
}

private struct WorkspaceSnapshot: Codable {
    var apps: [VirtualApp]
    var folders: [VirtualFolder]
    var sessions: [RuntimeSession]
    var settings: WorkspaceSettings
}

@MainActor
final class WorkspaceStore: ObservableObject {
    @Published private(set) var apps: [VirtualApp]
    @Published private(set) var folders: [VirtualFolder]
    @Published private(set) var sessions: [RuntimeSession]
    @Published var settings: WorkspaceSettings
    @Published var importError: String?

    private let fileManager = FileManager.default
    private let builtInID = UUID(uuidString: "A7A82D56-1F2C-4B27-9FA9-000000000001")!

    init() {
        apps = []
        folders = []
        sessions = []
        settings = WorkspaceSettings()
        load()
    }

    var pinnedApps: [VirtualApp] {
        apps.filter { $0.isPinned && $0.folderID == nil }
    }

    var homeApps: [VirtualApp] {
        apps.filter { $0.folderID == nil }.sorted { lhs, rhs in
            if lhs.isBuiltIn != rhs.isBuiltIn { return lhs.isBuiltIn }
            return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
        }
    }

    func apps(in folder: VirtualFolder) -> [VirtualApp] {
        apps.filter { $0.folderID == folder.id }
    }

    func app(for id: UUID) -> VirtualApp? {
        apps.first(where: { $0.id == id })
    }

    func open(_ app: VirtualApp) {
        if let index = apps.firstIndex(where: { $0.id == app.id }) {
            apps[index].lastOpened = .now
        }
        if let index = sessions.firstIndex(where: { $0.appID == app.id }) {
            sessions[index].state = .running
            sessions[index].lastUsed = .now
        } else {
            sessions.append(RuntimeSession(appID: app.id, state: .running, lastUsed: .now))
        }
        save()
    }

    func suspend(_ app: VirtualApp) {
        guard let index = sessions.firstIndex(where: { $0.appID == app.id }) else { return }
        sessions[index].state = .suspended
        sessions[index].lastUsed = .now
        save()
    }

    func close(_ app: VirtualApp) {
        sessions.removeAll { $0.appID == app.id }
        save()
    }

    func update(_ app: VirtualApp) {
        guard let index = apps.firstIndex(where: { $0.id == app.id }) else { return }
        apps[index] = app
        save()
    }

    func importIPA(from url: URL) {
        let hasAccess = url.startAccessingSecurityScopedResource()
        defer {
            if hasAccess { url.stopAccessingSecurityScopedResource() }
        }
        do {
            try fileManager.createDirectory(at: importsDirectory, withIntermediateDirectories: true)
            var destination = importsDirectory.appendingPathComponent(url.lastPathComponent)
            if fileManager.fileExists(atPath: destination.path) {
                let stem = destination.deletingPathExtension().lastPathComponent
                destination = importsDirectory.appendingPathComponent("\(stem)-\(UUID().uuidString.prefix(6)).ipa")
            }
            try fileManager.copyItem(at: url, to: destination)
            let name = destination.deletingPathExtension().lastPathComponent
                .replacingOccurrences(of: "_", with: " ")
                .replacingOccurrences(of: "-", with: " ")
            apps.append(VirtualApp(
                id: UUID(),
                displayName: name.isEmpty ? "Imported app" : name,
                bundleIdentifier: "imported.\(UUID().uuidString.prefix(8).lowercased())",
                version: "Imported",
                iconSymbol: "shippingbox.fill",
                iconColor: "teal",
                category: "Imported",
                ipaFileName: destination.lastPathComponent,
                isBuiltIn: false,
                isPinned: false,
                folderID: nil,
                status: .imported,
                addedAt: .now,
                lastOpened: nil
            ))
            save()
        } catch {
            importError = "Could not import \(url.lastPathComponent): \(error.localizedDescription)"
        }
    }

    func remove(_ app: VirtualApp) {
        guard !app.isBuiltIn else { return }
        if let fileName = app.ipaFileName {
            try? fileManager.removeItem(at: importsDirectory.appendingPathComponent(fileName))
        }
        apps.removeAll { $0.id == app.id }
        sessions.removeAll { $0.appID == app.id }
        save()
    }

    func createFolder(named name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        folders.append(VirtualFolder(id: UUID(), name: trimmed, symbol: "folder.fill"))
        save()
    }

    func deleteFolder(_ folder: VirtualFolder) {
        for index in apps.indices where apps[index].folderID == folder.id {
            apps[index].folderID = nil
        }
        folders.removeAll { $0.id == folder.id }
        save()
    }

    func move(_ app: VirtualApp, to folder: VirtualFolder?) {
        guard let index = apps.firstIndex(where: { $0.id == app.id }) else { return }
        apps[index].folderID = folder?.id
        save()
    }

    func resetWorkspace() {
        apps = [Self.seedHelloWorld(id: builtInID)]
        folders = []
        sessions = []
        settings = WorkspaceSettings()
        save()
    }

    func settingsDidChange() {
        save()
    }

    private var applicationSupportDirectory: URL {
        fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("HelloOS", isDirectory: true)
    }

    private var importsDirectory: URL {
        applicationSupportDirectory.appendingPathComponent("Imports", isDirectory: true)
    }

    private var stateURL: URL {
        applicationSupportDirectory.appendingPathComponent("workspace.json")
    }

    private func load() {
        do {
            let data = try Data(contentsOf: stateURL)
            let snapshot = try JSONDecoder().decode(WorkspaceSnapshot.self, from: data)
            apps = snapshot.apps
            folders = snapshot.folders
            sessions = snapshot.sessions
            settings = snapshot.settings
            if !apps.contains(where: { $0.id == builtInID }) {
                apps.insert(Self.seedHelloWorld(id: builtInID), at: 0)
            }
        } catch {
            apps = [Self.seedHelloWorld(id: builtInID)]
            folders = []
            sessions = []
            settings = WorkspaceSettings()
            save()
        }
    }

    private func save() {
        do {
            try fileManager.createDirectory(at: applicationSupportDirectory, withIntermediateDirectories: true)
            let snapshot = WorkspaceSnapshot(apps: apps, folders: folders, sessions: sessions, settings: settings)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(snapshot).write(to: stateURL, options: .atomic)
        } catch {
            importError = "Could not save workspace: \(error.localizedDescription)"
        }
    }

    private static func seedHelloWorld(id: UUID) -> VirtualApp {
        VirtualApp(
            id: id,
            displayName: "Hello World",
            bundleIdentifier: "com.example.helloworld",
            version: "1.0",
            iconSymbol: "hand.wave.fill",
            iconColor: "blue",
            category: "System",
            ipaFileName: nil,
            isBuiltIn: true,
            isPinned: true,
            folderID: nil,
            status: .builtIn,
            addedAt: .now,
            lastOpened: nil
        )
    }
}

extension Color {
    static func workspaceAccent(_ name: String) -> Color {
        switch name {
        case "blue": return .blue
        case "green": return .green
        case "orange": return .orange
        case "purple": return .purple
        case "pink": return .pink
        case "red": return .red
        case "indigo": return .indigo
        case "teal": return .teal
        default: return .blue
        }
    }
}

extension UTType {
    static var ipa: UTType {
        UTType(filenameExtension: "ipa") ?? .data
    }
}
