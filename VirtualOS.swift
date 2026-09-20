import Foundation
import SwiftUI
import UniformTypeIdentifiers

enum SystemAppKind: String, Codable, CaseIterable, Hashable {
    case helloWorld
    case appLibrary
    case settings
    case ipaSigner

    var displayName: String {
        switch self {
        case .helloWorld: return "Hello World"
        case .appLibrary: return "App Library"
        case .settings: return "Settings"
        case .ipaSigner: return "IPA Signer"
        }
    }

    var iconSymbol: String {
        switch self {
        case .helloWorld: return "hand.wave.fill"
        case .appLibrary: return "square.grid.2x2.fill"
        case .settings: return "gearshape.fill"
        case .ipaSigner: return "signature"
        }
    }

    var iconColor: String {
        switch self {
        case .helloWorld: return "blue"
        case .appLibrary: return "purple"
        case .settings: return "gray"
        case .ipaSigner: return "teal"
        }
    }

    var category: String {
        switch self {
        case .helloWorld: return "System"
        case .appLibrary, .settings, .ipaSigner: return "Utilities"
        }
    }
}

enum VirtualAppStatus: String, Codable, CaseIterable {
    case builtIn
    case imported
    case ready
    case unsupported

    var label: String {
        switch self {
        case .builtIn: return "System app"
        case .imported: return "Stored locally"
        case .ready: return "Ready"
        case .unsupported: return "Runtime unavailable"
        }
    }
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
    var systemApp: SystemAppKind?
}

struct VirtualFolder: Identifiable, Codable, Hashable {
    var id: UUID
    var name: String
    var symbol: String
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
    var settings: WorkspaceSettings

    enum CodingKeys: String, CodingKey {
        case apps
        case folders
        case settings
    }

    init(apps: [VirtualApp], folders: [VirtualFolder], settings: WorkspaceSettings) {
        self.apps = apps
        self.folders = folders
        self.settings = settings
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        apps = try container.decode([VirtualApp].self, forKey: .apps)
        folders = try container.decode([VirtualFolder].self, forKey: .folders)
        settings = try container.decode(WorkspaceSettings.self, forKey: .settings)
    }
}

@MainActor
final class WorkspaceStore: ObservableObject {
    @Published private(set) var apps: [VirtualApp]
    @Published private(set) var folders: [VirtualFolder]
    @Published var settings: WorkspaceSettings
    @Published var importError: String?
    @Published var signingMessage: String?

    private let fileManager = FileManager.default
    private let builtInIDs: [SystemAppKind: UUID] = [
        .helloWorld: UUID(uuidString: "A7A82D56-1F2C-4B27-9FA9-000000000001")!,
        .appLibrary: UUID(uuidString: "A7A82D56-1F2C-4B27-9FA9-000000000002")!,
        .settings: UUID(uuidString: "A7A82D56-1F2C-4B27-9FA9-000000000003")!,
        .ipaSigner: UUID(uuidString: "A7A82D56-1F2C-4B27-9FA9-000000000004")!
    ]

    init() {
        apps = []
        folders = []
        settings = WorkspaceSettings()
        load()
    }

    var pinnedApps: [VirtualApp] {
        apps.filter { $0.isPinned && $0.folderID == nil }.sorted { $0.addedAt < $1.addedAt }
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
        guard let index = apps.firstIndex(where: { $0.id == app.id }) else { return }
        apps[index].lastOpened = .now
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
                lastOpened: nil,
                systemApp: nil
            ))
            save()
        } catch {
            importError = "Could not import \(url.lastPathComponent): \(error.localizedDescription)"
        }
    }

    func ipaURL(for app: VirtualApp) -> URL? {
        guard let fileName = app.ipaFileName else { return nil }
        let url = importsDirectory.appendingPathComponent(fileName)
        return fileManager.fileExists(atPath: url.path) ? url : nil
    }

    func remove(_ app: VirtualApp) {
        guard !app.isBuiltIn else { return }
        if let fileName = app.ipaFileName {
            try? fileManager.removeItem(at: importsDirectory.appendingPathComponent(fileName))
        }
        apps.removeAll { $0.id == app.id }
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
        apps = Self.seedSystemApps(ids: builtInIDs)
        folders = []
        settings = WorkspaceSettings()
        signingMessage = nil
        save()
    }

    func settingsDidChange() {
        save()
    }

    func prepareSigning(for app: VirtualApp, certificateName: String, profileName: String) {
        guard ipaURL(for: app) != nil else {
            signingMessage = "The IPA is no longer available in app storage. Import it again before signing."
            return
        }
        guard !certificateName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !profileName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            signingMessage = "Choose a signing certificate and provisioning profile."
            return
        }
        signingMessage = "Signing configuration saved for \(app.displayName). A native ZSign backend must be linked before an IPA can be exported."
    }

    private var applicationSupportDirectory: URL {
        fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Workspace", isDirectory: true)
    }

    private var importsDirectory: URL {
        applicationSupportDirectory.appendingPathComponent("Imports", isDirectory: true)
    }

    private var stateURL: URL {
        applicationSupportDirectory.appendingPathComponent("workspace.json")
    }

    private var legacyApplicationSupportDirectory: URL {
        fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("HelloOS", isDirectory: true)
    }

    private func load() {
        do {
            try migrateLegacyWorkspaceIfNeeded()
            let data = try Data(contentsOf: stateURL)
            let snapshot = try JSONDecoder().decode(WorkspaceSnapshot.self, from: data)
            apps = snapshot.apps
            folders = snapshot.folders
            settings = snapshot.settings
            ensureSystemApps()
        } catch {
            apps = Self.seedSystemApps(ids: builtInIDs)
            folders = []
            settings = WorkspaceSettings()
            save()
        }
    }

    private func migrateLegacyWorkspaceIfNeeded() throws {
        guard !fileManager.fileExists(atPath: stateURL.path),
              fileManager.fileExists(atPath: legacyApplicationSupportDirectory.path) else { return }
        try fileManager.createDirectory(at: applicationSupportDirectory.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fileManager.copyItem(at: legacyApplicationSupportDirectory, to: applicationSupportDirectory)
    }

    private func ensureSystemApps() {
        var changed = false
        for kind in SystemAppKind.allCases {
            let expectedID = builtInIDs[kind]
            if let index = apps.firstIndex(where: { $0.id == expectedID || $0.systemApp == kind }) {
                if apps[index].systemApp != kind {
                    apps[index].systemApp = kind
                    changed = true
                }
                if !apps[index].isBuiltIn {
                    apps[index].isBuiltIn = true
                    changed = true
                }
                if apps[index].status != .builtIn {
                    apps[index].status = .builtIn
                    changed = true
                }
            } else if let expectedID {
                apps.append(Self.seedSystemApp(kind: kind, id: expectedID))
                changed = true
            }
        }
        if changed { save() }
    }

    private func save() {
        do {
            try fileManager.createDirectory(at: applicationSupportDirectory, withIntermediateDirectories: true)
            let snapshot = WorkspaceSnapshot(apps: apps, folders: folders, settings: settings)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(snapshot).write(to: stateURL, options: .atomic)
        } catch {
            importError = "Could not save workspace: \(error.localizedDescription)"
        }
    }

    private static func seedSystemApps(ids: [SystemAppKind: UUID]) -> [VirtualApp] {
        SystemAppKind.allCases.compactMap { kind in
            guard let id = ids[kind] else { return nil }
            return seedSystemApp(kind: kind, id: id)
        }
    }

    private static func seedSystemApp(kind: SystemAppKind, id: UUID) -> VirtualApp {
        VirtualApp(
            id: id,
            displayName: kind.displayName,
            bundleIdentifier: "com.example.workspace.\(kind.rawValue)",
            version: "1.0",
            iconSymbol: kind.iconSymbol,
            iconColor: kind.iconColor,
            category: kind.category,
            ipaFileName: nil,
            isBuiltIn: true,
            isPinned: true,
            folderID: nil,
            status: .builtIn,
            addedAt: .now,
            lastOpened: nil,
            systemApp: kind
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
        case "gray": return .gray
        default: return .blue
        }
    }
}

extension UTType {
    static var ipa: UTType {
        UTType(filenameExtension: "ipa") ?? .data
    }
}
