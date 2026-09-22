import Foundation
import SwiftUI
import CryptoKit

/// A module package published by the Workspace GitHub module feed.
///
/// The feed is intentionally separate from the IPA catalog.  A module package
/// is downloaded into Workspace Files / Modules and is never treated as an
/// executable merely because it has been downloaded.  The host must explicitly
/// know how to consume the package (for example, a model or a remote-builder
/// adapter) before it can be used.
struct WorkspaceDownloadableModule: Codable, Hashable, Identifiable {
    let id: String
    let title: String
    let version: String
    let summary: String
    let payload: WorkspaceModulePayloadKind
    let downloadURL: URL
    let sha256: String?
    let sizeBytes: Int64?
    let releaseURL: URL?

    var installedFileName: String {
        let safeTitle = title
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: "\\", with: "-")
            .replacingOccurrences(of: " ", with: "-")
        return "\(safeTitle)-\(version).workspace-module"
    }

    var moduleID: WorkspaceModuleID? { WorkspaceModuleID(rawValue: id) }

    var payloadLabel: String {
        switch payload {
        case .embeddedRuntime: return "Embedded runtime"
        case .embeddedAdapter: return "On-device adapter"
        case .remoteOnly: return "Remote builder"
        case .externalAssetRequired: return "External asset"
        }
    }
}

struct WorkspaceGitHubModuleManifest: Decodable {
    let name: String?
    let repository: String?
    let modules: [WorkspaceGitHubModuleEntry]
}

struct WorkspaceGitHubModuleEntry: Decodable {
    let id: String
    let title: String?
    let version: String?
    let summary: String?
    let payload: WorkspaceModulePayloadKind?
    let downloadURL: URL?
    let assetName: String?
    let sha256: String?
    let sizeBytes: Int64?
    let releaseURL: URL?

    enum CodingKeys: String, CodingKey {
        case id, title, version, summary, description, payload
        case downloadURL, downloadUrl, assetName, sha256, sizeBytes, size
        case releaseURL, releaseUrl
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        title = try values.decodeIfPresent(String.self, forKey: .title)
        version = try values.decodeIfPresent(String.self, forKey: .version)
        let decodedSummary = try values.decodeIfPresent(String.self, forKey: .summary)
        if let decodedSummary {
            summary = decodedSummary
        } else {
            summary = try values.decodeIfPresent(String.self, forKey: .description)
        }
        payload = try values.decodeIfPresent(WorkspaceModulePayloadKind.self, forKey: .payload)
        let explicitURL = try values.decodeIfPresent(URL.self, forKey: .downloadURL)
        if let explicitURL {
            downloadURL = explicitURL
        } else {
            downloadURL = try values.decodeIfPresent(URL.self, forKey: .downloadUrl)
        }
        assetName = try values.decodeIfPresent(String.self, forKey: .assetName)
        sha256 = try values.decodeIfPresent(String.self, forKey: .sha256)
        let explicitSize = try values.decodeIfPresent(Int64.self, forKey: .sizeBytes)
        if let explicitSize {
            sizeBytes = explicitSize
        } else {
            sizeBytes = try values.decodeIfPresent(Int64.self, forKey: .size)
        }
        let explicitReleaseURL = try values.decodeIfPresent(URL.self, forKey: .releaseURL)
        if let explicitReleaseURL {
            releaseURL = explicitReleaseURL
        } else {
            releaseURL = try values.decodeIfPresent(URL.self, forKey: .releaseUrl)
        }
    }
}

enum WorkspaceGitHubModuleCatalogError: LocalizedError {
    case invalidSource
    case requestFailed
    case invalidManifest
    case unsupportedModule(String)
    case invalidDownload
    case checksumMismatch
    case fileTooLarge

    var errorDescription: String? {
        switch self {
        case .invalidSource: return "Enter an HTTPS GitHub raw URL or GitHub repository URL."
        case .requestFailed: return "GitHub did not return a successful response."
        case .invalidManifest: return "The GitHub module feed is not a supported manifest."
        case .unsupportedModule(let id): return "The feed contains an unknown Workspace module: \(id)."
        case .invalidDownload: return "The downloaded module was empty or was not a valid HTTPS download."
        case .checksumMismatch: return "The module checksum did not match the feed. The file was discarded."
        case .fileTooLarge: return "The module exceeds the safe download limit."
        }
    }
}

@MainActor
final class WorkspaceGitHubModuleCatalog: ObservableObject {
    /// A public, raw GitHub URL is the safest default: it requires no token and
    /// does not expose the user's GitHub credentials to the module feed.
    static let defaultManifestURL = "https://raw.githubusercontent.com/Pkp107/HelloWorld-iOS27/main/modules.json"
    private static let sourceKey = "workspace.github.moduleManifestURL.v1"
    private static let maxDownloadBytes: Int64 = 2 * 1024 * 1024 * 1024

    @Published var sourceURL: String
    @Published private(set) var modules: [WorkspaceDownloadableModule] = []
    @Published private(set) var repositoryName = "GitHub modules"
    @Published private(set) var statusMessage: String?
    @Published private(set) var isLoading = false
    @Published private(set) var downloadingIDs: Set<String> = []
    @Published private(set) var downloadedIDs: Set<String> = []

    init() {
        sourceURL = UserDefaults.standard.string(forKey: Self.sourceKey) ?? Self.defaultManifestURL
    }

    func saveSource() {
        sourceURL = sourceURL.trimmingCharacters(in: .whitespacesAndNewlines)
        UserDefaults.standard.set(sourceURL, forKey: Self.sourceKey)
    }

    func refresh() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let url = try manifestURL(from: sourceURL)
            let request = makeRequest(url)
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                throw WorkspaceGitHubModuleCatalogError.requestFailed
            }
            let manifest = try JSONDecoder.workspaceModuleDecoder.decode(WorkspaceGitHubModuleManifest.self, from: data)
            let entries = try manifest.modules.map { try makeModule(from: $0, manifestURL: url) }
            modules = entries.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
            repositoryName = manifest.name ?? manifest.repository ?? url.host ?? "GitHub modules"
            statusMessage = "Updated \(modules.count) modules from GitHub."
        } catch {
            modules = []
            statusMessage = error.localizedDescription
        }
    }

    func download(_ module: WorkspaceDownloadableModule, store: WorkspaceStore, packageStore: WorkspaceModulePackageStore) async {
        guard downloadingIDs.insert(module.id).inserted else { return }
        defer { downloadingIDs.remove(module.id) }
        do {
            if let declaredSize = module.sizeBytes, declaredSize < 0 || declaredSize > Self.maxDownloadBytes {
                throw WorkspaceGitHubModuleCatalogError.fileTooLarge
            }
            let request = makeRequest(module.downloadURL)
            let (temporaryURL, response) = try await URLSession.shared.download(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                throw WorkspaceGitHubModuleCatalogError.requestFailed
            }
            guard let finalHost = response.url?.host?.lowercased(), isGitHubHost(finalHost) else {
                throw WorkspaceGitHubModuleCatalogError.invalidDownload
            }
            let values = try temporaryURL.resourceValues(forKeys: [.fileSizeKey])
            if let fileSize = values.fileSize, Int64(fileSize) > Self.maxDownloadBytes {
                throw WorkspaceGitHubModuleCatalogError.fileTooLarge
            }
            if let expected = normalizedChecksum(module.sha256) {
                let handle = try FileHandle(forReadingFrom: temporaryURL)
                var hasher = SHA256()
                while let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty {
                    hasher.update(data: chunk)
                }
                handle.closeFile()
                let digest = hasher.finalize()
                    .map { String(format: "%02x", $0) }.joined()
                guard digest.caseInsensitiveCompare(expected) == .orderedSame else {
                    throw WorkspaceGitHubModuleCatalogError.checksumMismatch
                }
            }
            let modulesDirectory = store.workspaceFolderDirectory(named: "Modules")
            try FileManager.default.createDirectory(at: modulesDirectory, withIntermediateDirectories: true)
            let destination = modulesDirectory.appendingPathComponent(module.installedFileName, isDirectory: false)
            // Replace an existing version only after the new file has been
            // downloaded and verified. This keeps a working package if the
            // final filesystem operation fails.
            if FileManager.default.fileExists(atPath: destination.path) {
                _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporaryURL)
            } else {
                try FileManager.default.moveItem(at: temporaryURL, to: destination)
            }
            store.workspaceFilesDidChange()
            if let moduleID = module.moduleID {
                packageStore.install(WorkspaceInstalledModulePackage(
                    moduleID: moduleID,
                    version: module.version,
                    fileName: destination.lastPathComponent,
                    sourceURL: module.downloadURL,
                    installedAt: .now
                ))
            }
            downloadedIDs.insert(module.id)
            statusMessage = "Downloaded \(module.title) to Workspace Files / Modules."
        } catch {
            statusMessage = "Could not download \(module.title): \(error.localizedDescription)"
        }
    }

    func isDownloaded(_ module: WorkspaceDownloadableModule, store: WorkspaceStore) -> Bool {
        if downloadedIDs.contains(module.id) { return true }
        let url = store.workspaceFolderDirectory(named: "Modules").appendingPathComponent(module.installedFileName)
        return FileManager.default.fileExists(atPath: url.path)
    }

    private func manifestURL(from raw: String) throws -> URL {
        guard let url = URL(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased(),
              host == "raw.githubusercontent.com" || host == "github.com" else {
            throw WorkspaceGitHubModuleCatalogError.invalidSource
        }
        // A GitHub repository URL is resolved to its conventional manifest path.
        if host == "github.com" {
            let pieces = url.path.split(separator: "/").map(String.init)
            if pieces.count >= 2 {
                return URL(string: "https://raw.githubusercontent.com/\(pieces[0])/\(pieces[1])/main/modules.json")!
            }
        }
        return url
    }

    private func makeModule(from entry: WorkspaceGitHubModuleEntry, manifestURL: URL) throws -> WorkspaceDownloadableModule {
        guard WorkspaceModuleID(rawValue: entry.id) != nil else {
            throw WorkspaceGitHubModuleCatalogError.unsupportedModule(entry.id)
        }
        let download: URL
        if let explicit = entry.downloadURL {
            download = explicit
        } else if let assetName = entry.assetName,
                  let base = manifestURL.deletingLastPathComponent().absoluteString.removingPercentEncoding,
                  let derived = URL(string: base + "/" + assetName) {
            download = derived
        } else {
            throw WorkspaceGitHubModuleCatalogError.invalidManifest
        }
        guard download.scheme?.lowercased() == "https",
              let host = download.host?.lowercased(), isGitHubHost(host) else {
            throw WorkspaceGitHubModuleCatalogError.invalidDownload
        }
        return WorkspaceDownloadableModule(
            id: entry.id,
            title: entry.title ?? WorkspaceModuleID(rawValue: entry.id)?.title ?? entry.id,
            version: entry.version ?? "latest",
            summary: entry.summary ?? WorkspaceModuleID(rawValue: entry.id)?.summary ?? "Workspace module package.",
            payload: entry.payload ?? WorkspaceModuleBundle.info(for: WorkspaceModuleID(rawValue: entry.id)!).payload,
            downloadURL: download,
            sha256: entry.sha256,
            sizeBytes: entry.sizeBytes,
            releaseURL: entry.releaseURL
        )
    }

    private func normalizedChecksum(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = value.lowercased().replacingOccurrences(of: "sha256:", with: "").filter { $0.isHexDigit }
        return normalized.count == 64 ? normalized : nil
    }

    private func isGitHubHost(_ host: String) -> Bool {
        host == "github.com" || host == "raw.githubusercontent.com" ||
        host == "objects.githubusercontent.com" || host.hasSuffix(".githubusercontent.com")
    }

    private func makeRequest(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Workspace-iOS27", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 120
        return request
    }
}

private extension JSONDecoder {
    static var workspaceModuleDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        return decoder
    }
}

struct InstallerModulesView: View {
    @ObservedObject var store: WorkspaceStore
    @StateObject private var catalog = WorkspaceGitHubModuleCatalog()
    @StateObject private var packageStore = WorkspaceModulePackageStore()
    @State private var sourceDraft = ""

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Download optional module packages from a public GitHub manifest. Downloads are stored in Workspace Files / Modules; the app will never execute an unknown package automatically.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    HStack {
                        Image(systemName: "link")
                            .foregroundStyle(.secondary)
                        TextField("GitHub raw modules.json URL", text: $sourceDraft)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                        Button("Save") {
                            catalog.sourceURL = sourceDraft
                            catalog.saveSource()
                            Task { await catalog.refresh() }
                        }
                        .disabled(sourceDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                } header: {
                    Text("Module feed")
                }

                Section(catalog.repositoryName) {
                    if catalog.modules.isEmpty {
                        Text("No downloadable packages are published in this GitHub feed yet.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(catalog.modules) { module in
                            InstallerModuleRow(module: module, isDownloaded: catalog.isDownloaded(module, store: store), isDownloading: catalog.downloadingIDs.contains(module.id)) {
                                Task { await catalog.download(module, store: store, packageStore: packageStore) }
                            }
                        }
                    }
                }

                Section("Built into this IPA") {
                    ForEach(WorkspaceModuleID.allCases) { moduleID in
                        BuiltInModuleRow(moduleID: moduleID)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Modules")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await catalog.refresh() }
                    } label: {
                        if catalog.isLoading { ProgressView() } else { Image(systemName: "arrow.clockwise") }
                    }
                    .disabled(catalog.isLoading)
                    .accessibilityLabel("Refresh GitHub modules")
                }
            }
            .task {
                sourceDraft = catalog.sourceURL
                await catalog.refresh()
            }
            .safeAreaInset(edge: .bottom) {
                if let status = catalog.statusMessage {
                    Text(status)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(.bar)
                }
            }
        }
    }
}

private struct BuiltInModuleRow: View {
    let moduleID: WorkspaceModuleID

    var body: some View {
        let info = WorkspaceModuleBundle.info(for: moduleID)
        HStack(spacing: 12) {
            Image(systemName: moduleID.symbol)
                .foregroundStyle(.white)
                .frame(width: 40, height: 40)
                .background(.gray, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(moduleID.title).font(.body.weight(.semibold))
                Text(info.payload.rawValue)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(info.artifactDescription)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
            }
            Spacer()
            Image(systemName: info.isPresentInIPA ? "checkmark.circle.fill" : "info.circle")
                .foregroundStyle(info.isPresentInIPA ? .green : .secondary)
        }
        .padding(.vertical, 4)
    }
}

private struct InstallerModuleRow: View {
    let module: WorkspaceDownloadableModule
    let isDownloaded: Bool
    let isDownloading: Bool
    let onDownload: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: WorkspaceModuleID(rawValue: module.id)?.symbol ?? "shippingbox.fill")
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(.purple, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(module.title).font(.body.weight(.semibold))
                Text("v\(module.version) · \(module.payloadLabel)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(module.summary)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
            }
            Spacer(minLength: 4)
            if isDownloading {
                ProgressView()
            } else if isDownloaded {
                Label("Saved", systemImage: "checkmark.circle.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.green)
            } else {
                Button("Download", action: onDownload)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
        }
        .padding(.vertical, 5)
    }
}
