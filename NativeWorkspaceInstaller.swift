#if LIVE_CONTAINER_NATIVE
import Foundation
import SwiftUI

/// Installs an IPA into the native LiveContainer application store.
///
/// LiveContainer's visible app list owns the same sequence internally, but
/// the Workspace installer is a separate surface. Keeping this bridge here
/// lets local files and repository downloads use that sequence without
/// requiring the LiveContainer list view to be on screen.
@MainActor
final class NativeWorkspaceInstaller: ObservableObject {
    static let shared = NativeWorkspaceInstaller()

    @Published private(set) var isInstalling = false
    @Published private(set) var progress: Double = 0
    @Published private(set) var installedAppName: String?
    @Published var errorMessage: String?

    // Keep a delegate alive for guest launches that need JIT. The home grid
    // has its own launcher object, but apps installed while that view is not
    // mounted still need the LiveContainer delegate callbacks.
    private let appDelegate = NativeWorkspaceHomeLauncher()

    private init() {}

    func install(url: URL) {
        guard !isInstalling else { return }

        isInstalling = true
        progress = 0
        errorMessage = nil
        installedAppName = nil

        Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await self.installIPA(at: url)
                self.progress = 1
                self.installedAppName = result.appName
                if let warning = result.warning {
                    self.errorMessage = warning
                }
            } catch {
                self.errorMessage = error.localizedDescription
            }
            self.isInstalling = false
        }
    }

    private struct InstallResult {
        let appName: String
        let warning: String?
    }

    private func installIPA(at url: URL) async throws -> InstallResult {
        let fileManager = FileManager.default
        let scoped = url.startAccessingSecurityScopedResource()
        defer {
            if scoped { url.stopAccessingSecurityScopedResource() }
        }

        guard fileManager.isReadableFile(atPath: url.path) else {
            throw NativeWorkspaceInstallerError.fileUnreadable(url.lastPathComponent)
        }
        guard ["ipa", "tipa", "zip"].contains(url.pathExtension.lowercased()) else {
            throw NativeWorkspaceInstallerError.invalidIPA
        }

        let workingDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("WorkspaceInstall-\(UUID().uuidString)", isDirectory: true)
        let payloadDirectory = workingDirectory.appendingPathComponent("Payload", isDirectory: true)
        try fileManager.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: workingDirectory) }

        let extractionProgress = Progress.discreteProgress(totalUnitCount: 100)
        extractionProgress.kind = .file
        extractionProgress.fileTotalCount = 1
        extractionProgress.cancellationHandler = { }
        let extractionResult = await decompress(url.path, workingDirectory.path, extractionProgress)
        guard extractionResult == 0 else {
            throw NativeWorkspaceInstallerError.invalidIPA
        }

        guard let appURL = try? fileManager.contentsOfDirectory(
            at: payloadDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ).first(where: { $0.pathExtension.lowercased() == "app" }) else {
            throw NativeWorkspaceInstallerError.missingAppBundle
        }

        guard let appInfo = LCAppInfo(bundlePath: appURL.path),
              let bundleIdentifier = appInfo.bundleIdentifier(),
              !bundleIdentifier.isEmpty else {
            throw NativeWorkspaceInstallerError.missingBundleIdentifier
        }

        try fileManager.createDirectory(at: LCPath.bundlePath, withIntermediateDirectories: true)
        let appRelativePath = nextApplicationPath(for: bundleIdentifier)
        let outputURL = LCPath.bundlePath.appendingPathComponent(appRelativePath, isDirectory: true)
        try fileManager.moveItem(at: appURL, to: outputURL)

        guard let finalAppInfo = LCAppInfo(bundlePath: outputURL.path) else {
            throw NativeWorkspaceInstallerError.appInfoUnavailable
        }
        finalAppInfo.relativeBundlePath = appRelativePath
        finalAppInfo.installationDate = Date()

        var signingWarning: String?
        let installProgress = Progress.discreteProgress(totalUnitCount: 100)
        installProgress.kind = .file
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            finalAppInfo.patchExecAndSignIfNeed(
                completionHandler: { success, error in
                    if !success {
                        signingWarning = error ?? "The app was installed but could not be signed. Configure a certificate in Installer first."
                    } else if let error, !error.isEmpty {
                        signingWarning = error
                    }
                    continuation.resume()
                },
                progressHandler: { progress in
                    guard let progress else { return }
                    installProgress.addChild(progress, withPendingUnitCount: 20)
                    Task { @MainActor [weak self] in
                        self?.progress = min(0.95, max(0.1, progress.fractionCompleted * 0.8 + 0.1))
                    }
                },
                forceSign: false
            )
        }

        finalAppInfo.save()
        let model = LCAppModel(appInfo: finalAppInfo, delegate: appDelegate)
        DataManager.shared.model.apps.append(model)
        if let urlSchemes = finalAppInfo.urlSchemes(), urlSchemes.count > 0 {
            UserDefaults.lcShared().mutableArrayValue(forKey: "LCGuestURLSchemes")
                .addObjects(from: urlSchemes as! [Any])
        }

        return InstallResult(appName: finalAppInfo.displayName(), warning: signingWarning)
    }

    private func nextApplicationPath(for bundleIdentifier: String) -> String {
        let fileManager = FileManager.default
        let safeIdentifier = bundleIdentifier.sanitizeNonACSII()
        let base = safeIdentifier.isEmpty ? "ImportedApp" : safeIdentifier
        var candidate = "\(base).app"
        var index = 2
        while fileManager.fileExists(atPath: LCPath.bundlePath.appendingPathComponent(candidate).path) {
            candidate = "\(base)_\(index).app"
            index += 1
        }
        return candidate
    }

    private nonisolated func decompress(_ path: String, _ destination: String, _ progress: Progress) async -> Int32 {
        extract(path, destination, progress)
    }
}

private enum NativeWorkspaceInstallerError: LocalizedError {
    case invalidIPA
    case fileUnreadable(String)
    case missingAppBundle
    case missingBundleIdentifier
    case appInfoUnavailable

    var errorDescription: String? {
        switch self {
        case .invalidIPA:
            return "The selected file is not a valid IPA archive."
        case .fileUnreadable(let name):
            return "Workspace could not read \(name). Copy it into Workspace Files first."
        case .missingAppBundle:
            return "The IPA does not contain Payload/*.app."
        case .missingBundleIdentifier:
            return "The app bundle does not contain a bundle identifier."
        case .appInfoUnavailable:
            return "LiveContainer could not read the installed app metadata."
        }
    }
}
#endif
