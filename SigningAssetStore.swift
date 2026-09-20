import Foundation
import Combine
import UniformTypeIdentifiers

enum WorkspaceCertificatePasswordStore {
    private static let key = "Workspace.CertificatePassword"
    private static let liveContainerKey = "LCCertificatePassword"

    static func load() -> String {
#if LIVE_CONTAINER_NATIVE
        if let password = LCUtils.appGroupUserDefault.string(forKey: liveContainerKey), !password.isEmpty {
            return password
        }
#endif
        return UserDefaults.standard.string(forKey: key)
            ?? UserDefaults.standard.string(forKey: liveContainerKey)
            ?? ""
    }

    static func save(_ password: String) {
        let value = password.trimmingCharacters(in: .whitespacesAndNewlines)
#if LIVE_CONTAINER_NATIVE
        LCUtils.appGroupUserDefault.set(value, forKey: liveContainerKey)
#endif
        UserDefaults.standard.set(value, forKey: key)
        // Keep the upstream LiveContainer key populated for its native signer.
        UserDefaults.standard.set(value, forKey: liveContainerKey)
    }
}

/// The two inputs the future ZSign adapter will need. The store keeps the
/// bytes inside the app container so a security-scoped importer URL is never
/// required after the import flow finishes.
enum SigningAssetKind: String, Codable, CaseIterable, Identifiable {
    case certificate
    case provisioningProfile

    var id: String { rawValue }

    var label: String {
        switch self {
        case .certificate:
            return "Certificate"
        case .provisioningProfile:
            return "Provisioning profile"
        }
    }

    var expectedExtensions: Set<String> {
        switch self {
        case .certificate:
            return ["p12", "pfx"]
        case .provisioningProfile:
            return ["mobileprovision", "provisionprofile"]
        }
    }

    /// Files providers do not consistently advertise signing assets as
    /// `public.data`: `.p12` and `.mobileprovision` may be exposed under a
    /// provider-specific UTI. Accept any file in the picker and enforce the
    /// extension after selection in `importAsset`.
    var fileImporterContentTypes: [UTType] {
        [.item]
    }
}

struct SigningAsset: Codable, Equatable, Identifiable {
    let id: UUID
    let kind: SigningAssetKind
    let originalName: String
    let storedName: String
    let byteCount: Int64
    let importedAt: Date
}

struct SigningPackage: Codable, Equatable, Identifiable {
    let id: UUID
    let originalName: String
    let storedName: String
    let byteCount: Int64
    let importedAt: Date
}

@MainActor
final class SigningAssetStore: ObservableObject {
    @Published private(set) var assets: [SigningAsset] = []
    @Published var errorMessage: String?

    private let fileManager: FileManager
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        migrateLegacyStorageIfNeeded()
        load()
    }

    func asset(for kind: SigningAssetKind) -> SigningAsset? {
        assets.last(where: { $0.kind == kind })
    }

    func url(for asset: SigningAsset) -> URL? {
        let url = signingDirectory.appendingPathComponent(asset.storedName, isDirectory: false)
        return fileManager.fileExists(atPath: url.path) ? url : nil
    }

    func data(for kind: SigningAssetKind) -> Data? {
        guard let asset = asset(for: kind), let assetURL = url(for: asset) else {
            return nil
        }
        return try? Data(contentsOf: assetURL, options: [.mappedIfSafe])
    }

    @discardableResult
    func importAsset(from sourceURL: URL, kind: SigningAssetKind) -> Bool {
        errorMessage = nil
        let hasAccess = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if hasAccess {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }

        do {
            guard fileManager.fileExists(atPath: sourceURL.path) else {
                throw SigningAssetError.sourceMissing
            }
            let data = try Data(contentsOf: sourceURL, options: [.mappedIfSafe])
            guard !data.isEmpty else {
                throw SigningAssetError.emptyFile
            }

            if let extensionName = normalizedExtension(for: sourceURL),
               !kind.expectedExtensions.contains(extensionName),
               extensionName != "data" {
                throw SigningAssetError.unexpectedFileType(kind: kind)
            }

            try fileManager.createDirectory(at: signingDirectory, withIntermediateDirectories: true)
            if let previous = asset(for: kind), let previousURL = url(for: previous) {
                try? fileManager.removeItem(at: previousURL)
            }

            let storedName = "\(kind.rawValue)-\(UUID().uuidString).\(sourceURL.pathExtension.isEmpty ? "bin" : sourceURL.pathExtension.lowercased())"
            let destinationURL = signingDirectory.appendingPathComponent(storedName, isDirectory: false)
            try data.write(to: destinationURL, options: [.atomic])
            try fileManager.setAttributes(
                [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                ofItemAtPath: destinationURL.path
            )

            let imported = SigningAsset(
                id: UUID(),
                kind: kind,
                originalName: sourceURL.lastPathComponent,
                storedName: storedName,
                byteCount: Int64(data.count),
                importedAt: .now
            )
            assets.removeAll { $0.kind == kind }
            assets.append(imported)
            try save()
            errorMessage = nil
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func remove(_ asset: SigningAsset) {
        errorMessage = nil
        if let storedURL = url(for: asset) {
            try? fileManager.removeItem(at: storedURL)
        }
        assets.removeAll { $0.id == asset.id }
        do {
            try save()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private var applicationSupportDirectory: URL {
#if LIVE_CONTAINER_NATIVE
        if let appGroupPath = LCSharedUtils.appGroupPath() {
            return appGroupPath.appendingPathComponent("Workspace-iOS27", isDirectory: true)
        }
#endif
        return fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Workspace-iOS27", isDirectory: true)
    }

    private var legacyApplicationSupportDirectory: URL {
#if LIVE_CONTAINER_NATIVE
        if let appGroupPath = LCSharedUtils.appGroupPath() {
            return appGroupPath.appendingPathComponent("Workspace", isDirectory: true)
        }
#endif
        return fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Workspace", isDirectory: true)
    }

    private var signingDirectory: URL {
        applicationSupportDirectory.appendingPathComponent("Signing", isDirectory: true)
    }

    private func incomingDirectory(for kind: SigningAssetKind) -> URL {
        signingDirectory
            .appendingPathComponent("Incoming", isDirectory: true)
            .appendingPathComponent(kind.rawValue, isDirectory: true)
    }

    private var manifestURL: URL {
        signingDirectory.appendingPathComponent("assets.json", isDirectory: false)
    }

    private func normalizedExtension(for url: URL) -> String? {
        let pathExtension = url.pathExtension.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !pathExtension.isEmpty else { return nil }
        return pathExtension.lowercased()
    }

    private func load() {
        if let data = try? Data(contentsOf: manifestURL) {
            do {
                assets = try decoder.decode([SigningAsset].self, from: data).filter { url(for: $0) != nil }
            } catch {
                errorMessage = "Could not load signing assets: \(error.localizedDescription)"
            }
        }
        consumeIncomingAssets()
    }

    private func migrateLegacyStorageIfNeeded() {
        let oldSigningDirectory = legacyApplicationSupportDirectory
            .appendingPathComponent("Signing", isDirectory: true)
        guard fileManager.fileExists(atPath: oldSigningDirectory.path),
              !fileManager.fileExists(atPath: signingDirectory.path) else { return }

        do {
            try fileManager.createDirectory(at: applicationSupportDirectory, withIntermediateDirectories: true)
            try fileManager.moveItem(at: oldSigningDirectory, to: signingDirectory)
        } catch {
            // A failed migration is harmless; the old data remains available for a later launch.
            errorMessage = "Could not migrate signing assets: \(error.localizedDescription)"
        }
    }

    private func consumeIncomingAssets() {
        var didImport = false
        for kind in SigningAssetKind.allCases {
            let directory = incomingDirectory(for: kind)
            guard let files = try? fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) else { continue }

            for sourceURL in files {
                guard let data = try? Data(contentsOf: sourceURL, options: [.mappedIfSafe]),
                      !data.isEmpty,
                      let extensionName = normalizedExtension(for: sourceURL),
                      kind.expectedExtensions.contains(extensionName) else { continue }

                do {
                    try fileManager.createDirectory(at: signingDirectory, withIntermediateDirectories: true)
                    if let previous = asset(for: kind), let previousURL = url(for: previous) {
                        try? fileManager.removeItem(at: previousURL)
                    }
                    let storedName = "\(kind.rawValue)-\(UUID().uuidString).\(extensionName)"
                    let destinationURL = signingDirectory.appendingPathComponent(storedName, isDirectory: false)
                    try data.write(to: destinationURL, options: [.atomic])
                    let imported = SigningAsset(
                        id: UUID(),
                        kind: kind,
                        originalName: sourceURL.lastPathComponent,
                        storedName: storedName,
                        byteCount: Int64(data.count),
                        importedAt: .now
                    )
                    assets.removeAll { $0.kind == kind }
                    assets.append(imported)
                    try? fileManager.removeItem(at: sourceURL)
                    didImport = true
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
        }
        if didImport {
            try? save()
        }
    }

    private func save() throws {
        try fileManager.createDirectory(at: signingDirectory, withIntermediateDirectories: true)
        try encoder.encode(assets).write(to: manifestURL, options: [.atomic])
    }
}

/// IPA Signer owns this package store. It deliberately does not share the
/// Installer or LiveContainer import directory, so a package can be signed
/// without adding it to Workspace's runtime.
@MainActor
final class SigningPackageStore: ObservableObject {
    @Published private(set) var package: SigningPackage?
    @Published var errorMessage: String?

    private let fileManager: FileManager
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        load()
    }

    var packageURL: URL? {
        guard let package else { return nil }
        let url = packagesDirectory.appendingPathComponent(package.storedName, isDirectory: false)
        return fileManager.fileExists(atPath: url.path) ? url : nil
    }

    @discardableResult
    func importPackage(from sourceURL: URL) -> Bool {
        errorMessage = nil
        let hasAccess = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if hasAccess { sourceURL.stopAccessingSecurityScopedResource() }
        }

        do {
            let fileExtension = sourceURL.pathExtension.lowercased()
            guard fileExtension == "ipa" || fileExtension == "zip" else {
                throw SigningPackageError.unsupportedFile
            }
            let data = try Data(contentsOf: sourceURL, options: [.mappedIfSafe])
            guard !data.isEmpty else { throw SigningPackageError.emptyFile }

            try fileManager.createDirectory(at: packagesDirectory, withIntermediateDirectories: true)
            if let oldURL = packageURL { try? fileManager.removeItem(at: oldURL) }

            let storedName = UUID().uuidString + ".ipa"
            let destination = packagesDirectory.appendingPathComponent(storedName, isDirectory: false)
            try data.write(to: destination, options: [.atomic])
            try fileManager.setAttributes(
                [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                ofItemAtPath: destination.path
            )
            package = SigningPackage(
                id: UUID(),
                originalName: sourceURL.lastPathComponent,
                storedName: storedName,
                byteCount: Int64(data.count),
                importedAt: .now
            )
            try save()
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func removePackage() {
        if let packageURL { try? fileManager.removeItem(at: packageURL) }
        package = nil
        try? fileManager.removeItem(at: manifestURL)
    }

    private var applicationSupportDirectory: URL {
        fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Workspace", isDirectory: true)
    }

    private var packagesDirectory: URL {
        applicationSupportDirectory.appendingPathComponent("Signing/Packages", isDirectory: true)
    }

    private var manifestURL: URL {
        packagesDirectory.appendingPathComponent("package.json", isDirectory: false)
    }

    private func load() {
        guard let data = try? Data(contentsOf: manifestURL),
              let stored = try? decoder.decode(SigningPackage.self, from: data) else { return }
        let url = packagesDirectory.appendingPathComponent(stored.storedName, isDirectory: false)
        package = fileManager.fileExists(atPath: url.path) ? stored : nil
    }

    private func save() throws {
        try fileManager.createDirectory(at: packagesDirectory, withIntermediateDirectories: true)
        guard let package else { return }
        try encoder.encode(package).write(to: manifestURL, options: [.atomic])
    }
}

private enum SigningAssetError: LocalizedError {
    case sourceMissing
    case emptyFile
    case unexpectedFileType(kind: SigningAssetKind)

    var errorDescription: String? {
        switch self {
        case .sourceMissing:
            return "The selected signing file could not be read."
        case .emptyFile:
            return "The selected signing file is empty."
        case .unexpectedFileType(let kind):
            return "Choose a supported file for \(kind.label)."
        }
    }
}

private enum SigningPackageError: LocalizedError {
    case unsupportedFile
    case emptyFile

    var errorDescription: String? {
        switch self {
        case .unsupportedFile: return "Choose an IPA file."
        case .emptyFile: return "The selected IPA is empty."
        }
    }
}
