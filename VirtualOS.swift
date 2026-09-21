import Foundation
import SwiftUI
import UniformTypeIdentifiers

enum SystemAppKind: String, Codable, CaseIterable, Hashable {
    case helloWorld
    // Kept as a source-compatible spelling for older callers. Persisted
    // `appLibrary` values decode to `liveContainer` below and this legacy
    // case is intentionally excluded from `allCases` so it is never seeded.
    case appLibrary
    case settings
    // Retained for decoding older workspace snapshots. Installer now owns
    // signing and guest installation in one surface, so this is no longer a
    // launcher icon.
    case ipaSigner
    case installer
    case liveContainer
    case liveContainerSettings
    case fileManager
    case devStudio
    case github
    case inspector
    case network
    case remoteDesktop

    static var allCases: [SystemAppKind] {
        [.helloWorld, .installer, .fileManager, .devStudio, .github, .inspector, .network, .remoteDesktop, .settings]
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        if rawValue == "appLibrary" {
            self = .liveContainer
            return
        }
        guard let value = SystemAppKind(rawValue: rawValue) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unknown system app kind: \(rawValue)"
            )
        }
        self = value
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    var displayName: String {
        switch self {
        case .helloWorld: return "Hello World"
        case .appLibrary: return "Installed Apps"
        case .settings: return "Settings"
        case .ipaSigner: return "IPA Signer"
        case .installer: return "Installer"
        case .liveContainer: return "LiveContainer"
        case .liveContainerSettings: return "LiveContainer Settings"
        case .fileManager: return "File Manager"
        case .devStudio: return "Dev Studio"
        case .github: return "GitHub"
        case .inspector: return "Inspector"
        case .network: return "Network"
        case .remoteDesktop: return "Remote Desktop"
        }
    }

    var iconSymbol: String {
        switch self {
        case .helloWorld: return "hand.wave.fill"
        case .appLibrary: return "square.grid.2x2.fill"
        case .settings: return "gearshape.fill"
        case .ipaSigner: return "signature"
        case .installer: return "bag.fill"
        case .liveContainer: return "shippingbox.and.arrow.backward.fill"
        case .liveContainerSettings: return "bolt.circle.fill"
        case .fileManager: return "folder.fill"
        case .devStudio: return "hammer.fill"
        case .github: return "arrow.triangle.branch"
        case .inspector: return "ladybug.fill"
        case .network: return "network"
        case .remoteDesktop: return "rectangle.on.rectangle"
        }
    }

    var iconColor: String {
        switch self {
        case .helloWorld: return "blue"
        case .appLibrary: return "purple"
        case .settings: return "gray"
        case .ipaSigner: return "teal"
        case .installer: return "orange"
        case .liveContainer: return "green"
        case .liveContainerSettings: return "indigo"
        case .fileManager: return "teal"
        case .devStudio: return "blue"
        case .github: return "purple"
        case .inspector: return "orange"
        case .network: return "green"
        case .remoteDesktop: return "indigo"
        }
    }

    var category: String {
        switch self {
        case .helloWorld: return "System"
        case .appLibrary, .settings, .ipaSigner, .installer, .liveContainer, .liveContainerSettings, .fileManager: return "Utilities"
        case .devStudio, .github, .inspector, .network, .remoteDesktop: return "Developer"
        }
    }
}

enum WallpaperOption: String, Codable, CaseIterable, Identifiable, Hashable {
    case aurora
    case midnight
    case ocean
    case sunrise
    case forest
    case custom

    var id: String { rawValue }

    var label: String {
        switch self {
        case .aurora: return "Aurora"
        case .midnight: return "Midnight"
        case .ocean: return "Ocean"
        case .sunrise: return "Sunrise"
        case .forest: return "Forest"
        case .custom: return "Custom photo"
        }
    }

    var iconSymbol: String {
        switch self {
        case .custom: return "photo"
        default: return "rectangle.inset.filled"
        }
    }
}

enum GlassStyle: String, Codable, CaseIterable, Identifiable, Hashable {
    case frosted
    case clear
    case tinted
    case opaque

    var id: String { rawValue }

    var label: String {
        switch self {
        case .frosted: return "Frosted"
        case .clear: return "Clear"
        case .tinted: return "Tinted"
        case .opaque: return "Opaque"
        }
    }
}

enum LaunchMode: String, Codable, CaseIterable, Identifiable, Hashable {
    case automatic
    case single
    case parallel

    var id: String { rawValue }

    var label: String {
        switch self {
        case .automatic: return "Automatic"
        case .single: return "Single app"
        case .parallel: return "Parallel apps"
        }
    }
}

enum JITProvider: String, Codable, CaseIterable, Identifiable, Hashable {
    case unconfigured
    case certificate
    case jitStreamer

    var id: String { rawValue }

    var label: String {
        switch self {
        case .unconfigured: return "Not configured"
        case .certificate: return "Certificate"
        case .jitStreamer: return "JIT Streamer"
        }
    }
}

enum OnboardingStep: String, Codable, CaseIterable, Identifiable, Hashable {
    case welcome
    case runtime
    case jit
    case wallpaper
    case appearance
    case complete

    var id: String { rawValue }
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
    var homeOrder: Int? = nil
}

extension VirtualApp {
    private enum CodingKeys: String, CodingKey {
        case id, displayName, bundleIdentifier, version, iconSymbol, iconColor, category, ipaFileName, isBuiltIn, isPinned, folderID, status, addedAt, lastOpened, systemApp, homeOrder
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        displayName = try c.decode(String.self, forKey: .displayName)
        bundleIdentifier = try c.decode(String.self, forKey: .bundleIdentifier)
        version = try c.decode(String.self, forKey: .version)
        iconSymbol = try c.decode(String.self, forKey: .iconSymbol)
        iconColor = try c.decode(String.self, forKey: .iconColor)
        category = try c.decode(String.self, forKey: .category)
        ipaFileName = try c.decodeIfPresent(String.self, forKey: .ipaFileName)
        isBuiltIn = try c.decode(Bool.self, forKey: .isBuiltIn)
        isPinned = try c.decode(Bool.self, forKey: .isPinned)
        folderID = try c.decodeIfPresent(UUID.self, forKey: .folderID)
        status = try c.decode(VirtualAppStatus.self, forKey: .status)
        addedAt = try c.decode(Date.self, forKey: .addedAt)
        lastOpened = try c.decodeIfPresent(Date.self, forKey: .lastOpened)
        systemApp = try c.decodeIfPresent(SystemAppKind.self, forKey: .systemApp)
        homeOrder = try c.decodeIfPresent(Int.self, forKey: .homeOrder)
    }
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

    var wallpaper: WallpaperOption = .aurora
    var customWallpaperFileName: String?
    var glassStyle: GlassStyle = .frosted
    var glassOpacity = 0.78
    var glassBlurRadius = 20.0

    var launchMode: LaunchMode = .automatic
    var jitProvider: JITProvider = .unconfigured
    var jitEnabled = false
    var jitAppIDs: Set<UUID> = []

    var backgroundExecutionEnabled = true
    var backgroundAppLimit = 3
    var showDockRecents = true
    var perAppAudioEnabled = true
    var appAudioLevels: [String: Double] = [:]
    var mutedAppIDs: Set<UUID> = []

    var onboardingCompleted = false
    var onboardingStep: OnboardingStep = .welcome

    var hasCompletedOnboarding: Bool {
        get { onboardingCompleted }
        set { onboardingCompleted = newValue }
    }

    private enum CodingKeys: String, CodingKey {
        case showAppLabels
        case gridColumns
        case confirmRemoval
        case reduceShellMotion
        case wallpaper
        case customWallpaperFileName
        case glassStyle
        case glassOpacity
        case glassBlurRadius
        case launchMode
        case jitProvider
        case jitEnabled
        case jitAppIDs
        case backgroundExecutionEnabled
        case backgroundAppLimit
        case showDockRecents
        case perAppAudioEnabled
        case appAudioLevels
        case mutedAppIDs
        case onboardingCompleted
        case onboardingStep
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        showAppLabels = try container.decodeIfPresent(Bool.self, forKey: .showAppLabels) ?? true
        gridColumns = try container.decodeIfPresent(Int.self, forKey: .gridColumns) ?? 4
        confirmRemoval = try container.decodeIfPresent(Bool.self, forKey: .confirmRemoval) ?? true
        reduceShellMotion = try container.decodeIfPresent(Bool.self, forKey: .reduceShellMotion) ?? false

        wallpaper = (try? container.decodeIfPresent(WallpaperOption.self, forKey: .wallpaper)) ?? .aurora
        customWallpaperFileName = try container.decodeIfPresent(String.self, forKey: .customWallpaperFileName)
        glassStyle = (try? container.decodeIfPresent(GlassStyle.self, forKey: .glassStyle)) ?? .frosted
        glassOpacity = try container.decodeIfPresent(Double.self, forKey: .glassOpacity) ?? 0.78
        glassBlurRadius = try container.decodeIfPresent(Double.self, forKey: .glassBlurRadius) ?? 20

        launchMode = (try? container.decodeIfPresent(LaunchMode.self, forKey: .launchMode)) ?? .automatic
        jitProvider = (try? container.decodeIfPresent(JITProvider.self, forKey: .jitProvider)) ?? .unconfigured
        jitEnabled = try container.decodeIfPresent(Bool.self, forKey: .jitEnabled) ?? false
        jitAppIDs = try container.decodeIfPresent(Set<UUID>.self, forKey: .jitAppIDs) ?? []

        backgroundExecutionEnabled = try container.decodeIfPresent(Bool.self, forKey: .backgroundExecutionEnabled) ?? true
        backgroundAppLimit = try container.decodeIfPresent(Int.self, forKey: .backgroundAppLimit) ?? 3
        showDockRecents = try container.decodeIfPresent(Bool.self, forKey: .showDockRecents) ?? true
        perAppAudioEnabled = try container.decodeIfPresent(Bool.self, forKey: .perAppAudioEnabled) ?? true
        appAudioLevels = try container.decodeIfPresent([String: Double].self, forKey: .appAudioLevels) ?? [:]
        mutedAppIDs = try container.decodeIfPresent(Set<UUID>.self, forKey: .mutedAppIDs) ?? []

        onboardingCompleted = try container.decodeIfPresent(Bool.self, forKey: .onboardingCompleted) ?? false
        onboardingStep = (try? container.decodeIfPresent(OnboardingStep.self, forKey: .onboardingStep)) ?? (onboardingCompleted ? .complete : .welcome)
    }
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
        .settings: UUID(uuidString: "A7A82D56-1F2C-4B27-9FA9-000000000003")!,
        .ipaSigner: UUID(uuidString: "A7A82D56-1F2C-4B27-9FA9-000000000004")!,
        .installer: UUID(uuidString: "A7A82D56-1F2C-4B27-9FA9-000000000005")!,
        // Reuse the old App Library identifier so migration maps that app in
        // place instead of adding a duplicate LiveContainer icon.
        .liveContainer: UUID(uuidString: "A7A82D56-1F2C-4B27-9FA9-000000000002")!,
        .fileManager: UUID(uuidString: "A7A82D56-1F2C-4B27-9FA9-000000000007")!,
        .devStudio: UUID(uuidString: "A7A82D56-1F2C-4B27-9FA9-000000000008")!,
        .github: UUID(uuidString: "A7A82D56-1F2C-4B27-9FA9-000000000009")!,
        .inspector: UUID(uuidString: "A7A82D56-1F2C-4B27-9FA9-000000000010")!,
        .network: UUID(uuidString: "A7A82D56-1F2C-4B27-9FA9-000000000011")!,
        .remoteDesktop: UUID(uuidString: "A7A82D56-1F2C-4B27-9FA9-000000000012")!
    ]

    init() {
        apps = []
        folders = []
        settings = WorkspaceSettings()
        ensureWorkspaceFileFolders()
        load()
    }

    var pinnedApps: [VirtualApp] {
        apps.filter { $0.isPinned && $0.folderID == nil }.sorted { $0.addedAt < $1.addedAt }
    }

    var homeApps: [VirtualApp] {
        apps.filter { $0.folderID == nil }.sorted { lhs, rhs in
            switch (lhs.homeOrder, rhs.homeOrder) {
            case let (left?, right?) where left != right: return left < right
            case (_?, nil): return true
            case (nil, _?): return false
            default:
                if lhs.isBuiltIn != rhs.isBuiltIn { return lhs.isBuiltIn }
                return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
            }
        }
    }

    func reorderHomeApps(from source: UUID, to target: UUID) {
        let ordered = homeApps
        guard let sourceIndex = ordered.firstIndex(where: { $0.id == source }),
              let targetIndex = ordered.firstIndex(where: { $0.id == target }),
              sourceIndex != targetIndex else { return }
        var ids = ordered.map(\.id)
        let moved = ids.remove(at: sourceIndex)
        ids.insert(moved, at: max(0, min(targetIndex, ids.count)))
        for (index, id) in ids.enumerated() {
            guard let appIndex = apps.firstIndex(where: { $0.id == id }) else { continue }
            apps[appIndex].homeOrder = index
        }
        save()
    }

    /// Non-system packages managed by the LiveContainer runtime.
    var installedApps: [VirtualApp] {
        apps.filter { !$0.isBuiltIn }
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    var liveContainerApps: [VirtualApp] { installedApps }

    var needsOnboarding: Bool { !settings.onboardingCompleted }

    var wallpaperURL: URL? {
        guard settings.wallpaper == .custom,
              let fileName = settings.customWallpaperFileName else { return nil }
        let url = wallpapersDirectory.appendingPathComponent(fileName, isDirectory: false)
        return fileManager.fileExists(atPath: url.path) ? url : nil
    }

    /// Files visible in the app's Documents directory. Users can copy IPAs,
    /// certificates, and provisioning profiles here from Files, then select
    /// them without reopening the provider picker.
    var workspaceFilesDirectory: URL {
        fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Workspace Files", isDirectory: true)
    }

    private var workspaceFileFolders: [String] {
        ["Incoming", "IPAs", "Certificates", "Provisioning Profiles", "Downloads", "Signed"]
    }

    func workspaceFolderDirectory(named name: String) -> URL {
        workspaceFilesDirectory.appendingPathComponent(name, isDirectory: true)
    }

    private func ensureWorkspaceFileFolders() {
        try? fileManager.createDirectory(at: workspaceFilesDirectory, withIntermediateDirectories: true)
        for folder in workspaceFileFolders {
            try? fileManager.createDirectory(at: workspaceFolderDirectory(named: folder), withIntermediateDirectories: true)
        }
    }

    func workspaceFiles() -> [URL] {
        guard fileManager.fileExists(atPath: workspaceFilesDirectory.path) else { return [] }
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
        let enumerator = fileManager.enumerator(
            at: workspaceFilesDirectory,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        )
        return (enumerator?.compactMap { item -> URL? in
            guard let url = item as? URL,
                  (try? url.resourceValues(forKeys: keys).isDirectory) != true else { return nil }
            return url
        } ?? []).sorted { $0.path.localizedCaseInsensitiveCompare($1.path) == .orderedAscending }
    }

    @discardableResult
    func copyToWorkspaceFiles(from sourceURL: URL) -> URL? {
        let hasAccess = sourceURL.startAccessingSecurityScopedResource()
        defer { if hasAccess { sourceURL.stopAccessingSecurityScopedResource() } }
        do {
            try fileManager.createDirectory(at: workspaceFilesDirectory, withIntermediateDirectories: true)
            let baseName = sourceURL.lastPathComponent.isEmpty ? "Imported file" : sourceURL.lastPathComponent
            let ext = sourceURL.pathExtension.lowercased()
            let folder: String
            switch ext {
            case "ipa", "tipa", "zip": folder = "IPAs"
            case "p12", "pfx": folder = "Certificates"
            case "mobileprovision", "provisionprofile": folder = "Provisioning Profiles"
            default: folder = "Incoming"
            }
            let destinationFolder = workspaceFolderDirectory(named: folder)
            try fileManager.createDirectory(at: destinationFolder, withIntermediateDirectories: true)
            var destination = destinationFolder.appendingPathComponent(baseName, isDirectory: false)
            if fileManager.fileExists(atPath: destination.path) {
                destination = destinationFolder.appendingPathComponent(
                    "\(destination.deletingPathExtension().lastPathComponent)-\(UUID().uuidString.prefix(6)).\(destination.pathExtension)",
                    isDirectory: false
                )
            }
            try fileManager.copyItem(at: sourceURL, to: destination)
            objectWillChange.send()
            return destination
        } catch {
            importError = "Could not copy \(sourceURL.lastPathComponent): \(error.localizedDescription)"
            return nil
        }
    }

    func deleteWorkspaceFile(_ url: URL) {
        let rootPath = workspaceFilesDirectory.standardizedFileURL.path
        let filePath = url.standardizedFileURL.path
        guard filePath.hasPrefix(rootPath + "/") else { return }
        do {
            try fileManager.removeItem(at: url)
            objectWillChange.send()
        } catch {
            importError = "Could not delete \(url.lastPathComponent): \(error.localizedDescription)"
        }
    }

    /// Refreshes views that display the app-owned Documents folder after a
    /// background download writes a new file there.
    func workspaceFilesDidChange() {
        objectWillChange.send()
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

    /// Imports an IPA into the installer-managed package store.
    func installerImportIPA(from url: URL) {
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
#if LIVE_CONTAINER_NATIVE
            // The native target uses the actual LiveContainer app store. Keep
            // the copied package in Workspace storage while the asynchronous
            // installer consumes an app-owned URL.
            NativeWorkspaceInstaller.shared.install(url: destination)
#else
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
                systemApp: nil,
                homeOrder: nil
            ))
            save()
#endif
        } catch {
            importError = "Could not import \(url.lastPathComponent): \(error.localizedDescription)"
        }
    }

    /// Compatibility entry point for existing callers. New installer UI
    /// should call `installerImportIPA(from:)` directly.
    func importIPA(from url: URL) {
        installerImportIPA(from: url)
    }

    func installIPA(from url: URL) {
        installerImportIPA(from: url)
    }

    func selectWallpaper(_ option: WallpaperOption) {
        settings.wallpaper = option
        if option != .custom {
            settings.customWallpaperFileName = nil
        }
        save()
    }

    @discardableResult
    func importWallpaper(from url: URL) -> Bool {
        let hasAccess = url.startAccessingSecurityScopedResource()
        defer {
            if hasAccess { url.stopAccessingSecurityScopedResource() }
        }

        do {
            guard fileManager.fileExists(atPath: url.path) else {
                throw CocoaError(.fileNoSuchFile)
            }
            let ext = url.pathExtension.lowercased()
            guard ["jpg", "jpeg", "png", "heic", "heif", "webp"].contains(ext) else {
                throw CocoaError(.fileReadUnsupportedScheme)
            }
            try fileManager.createDirectory(at: wallpapersDirectory, withIntermediateDirectories: true)
            if let oldName = settings.customWallpaperFileName {
                try? fileManager.removeItem(at: wallpapersDirectory.appendingPathComponent(oldName))
            }
            let storedName = "wallpaper-\(UUID().uuidString).\(ext)"
            let destination = wallpapersDirectory.appendingPathComponent(storedName, isDirectory: false)
            try fileManager.copyItem(at: url, to: destination)
            settings.wallpaper = .custom
            settings.customWallpaperFileName = storedName
            save()
            return true
        } catch {
            importError = "Could not import wallpaper: \(error.localizedDescription)"
            return false
        }
    }

    func removeCustomWallpaper() {
        if let fileName = settings.customWallpaperFileName {
            try? fileManager.removeItem(at: wallpapersDirectory.appendingPathComponent(fileName))
        }
        settings.customWallpaperFileName = nil
        if settings.wallpaper == .custom {
            settings.wallpaper = .aurora
        }
        save()
    }

    func setOnboardingStep(_ step: OnboardingStep) {
        settings.onboardingStep = step
        if step == .complete {
            settings.onboardingCompleted = true
        }
        save()
    }

    func completeOnboarding() {
        settings.onboardingStep = .complete
        settings.onboardingCompleted = true
        save()
    }

    func resetOnboarding() {
        settings.onboardingStep = .welcome
        settings.onboardingCompleted = false
        save()
    }

    func setAudioLevel(_ level: Double, for app: VirtualApp) {
        settings.appAudioLevels[app.id.uuidString] = min(max(level, 0), 1)
        save()
    }

    func audioLevel(for app: VirtualApp) -> Double {
        settings.appAudioLevels[app.id.uuidString] ?? 1
    }

    func setMuted(_ muted: Bool, for app: VirtualApp) {
        if muted {
            settings.mutedAppIDs.insert(app.id)
        } else {
            settings.mutedAppIDs.remove(app.id)
        }
        save()
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

    private var wallpapersDirectory: URL {
        applicationSupportDirectory.appendingPathComponent("Wallpapers", isDirectory: true)
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
            removeRetiredSystemApps()
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
                if kind == .liveContainer, apps[index].displayName == "App Library" {
                    apps[index].displayName = kind.displayName
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

    /// LiveContainer controls now live inside Settings. Remove the old
    /// standalone launcher icon when loading a workspace created by an
    /// earlier build.
    private func removeRetiredSystemApps() {
        let retiredID = UUID(uuidString: "A7A82D56-1F2C-4B27-9FA9-000000000006")!
        let oldCount = apps.count
        apps.removeAll {
            $0.id == retiredID || $0.systemApp == .liveContainerSettings || $0.systemApp == .ipaSigner || $0.systemApp == .liveContainer
        }
        if apps.count != oldCount { save() }
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
            systemApp: kind,
            homeOrder: SystemAppKind.allCases.firstIndex(of: kind)
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

#if !LIVE_CONTAINER_NATIVE
extension UTType {
    static var ipa: UTType {
        UTType(filenameExtension: "ipa") ?? .data
    }
}
#endif
