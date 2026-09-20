#if LIVE_CONTAINER_NATIVE
import SwiftUI
import UIKit
import Darwin

struct NativeLiveContainerAppLibraryView: View {
    @StateObject private var downloadHelper = DownloadHelper()

    var body: some View {
        LCAppListView()
            .environmentObject(DataManager.shared.model)
            .environmentObject(LCAppSortManager.shared)
            .environmentObject(downloadHelper)
    }
}

struct NativeLiveContainerSettingsView: View {
    var body: some View {
        LCSettingsView()
            .environmentObject(DataManager.shared.model)
    }
}

/// Mirrors LiveContainer's installed-app model on the fixed Workspace home
/// surface. The original LiveContainer list remains available from its own
/// launcher entry for app management.
struct NativeLiveContainerHomeGrid: View {
    let columns: Int
    let showLabels: Bool

    @EnvironmentObject private var sharedModel: SharedModel
    @StateObject private var launcher = NativeWorkspaceHomeLauncher()

    private var gridColumns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 18), count: max(2, min(columns, 5)))
    }

    var body: some View {
        LazyVGrid(columns: gridColumns, alignment: .leading, spacing: 22) {
            ForEach(sharedModel.apps, id: \.self) { app in
                Button {
                    launcher.launch(app)
                } label: {
                    VStack(spacing: 7) {
                        if let icon = app.appInfo.iconIsDarkIcon(false) {
                            Image(uiImage: icon)
                                .resizable()
                                .scaledToFill()
                                .frame(width: 62, height: 62)
                                .clipShape(RoundedRectangle(cornerRadius: 17, style: .continuous))
                        } else {
                            Image(systemName: "app.fill")
                                .font(.system(size: 25, weight: .semibold))
                                .foregroundStyle(.white)
                                .frame(width: 62, height: 62)
                                .background(.green, in: RoundedRectangle(cornerRadius: 17, style: .continuous))
                        }
                        if showLabels {
                            Text(app.displayName)
                                .font(.caption.weight(.medium))
                                .lineLimit(2)
                                .multilineTextAlignment(.center)
                                .foregroundStyle(.primary)
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: showLabels ? 91 : 62)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(app.displayName)
                .accessibilityHint("Opens LiveContainer app")
            }
        }
        .alert("Could not open app", isPresented: Binding(
            get: { launcher.errorMessage != nil },
            set: { if !$0 { launcher.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { launcher.errorMessage = nil }
        } message: {
            Text(launcher.errorMessage ?? "")
        }
    }
}

@MainActor
final class NativeWorkspaceHomeLauncher: NSObject, ObservableObject, LCAppModelDelegate {
    @Published var errorMessage: String?

    func launch(_ app: LCAppModel) {
        app.delegate = self
        Task {
            do {
                try await app.runApp()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func closeNavigationView() {}

    func changeAppVisibility(app: LCAppModel) {}

    func jitLaunch(appName: String, classicMode: UInt) async {
        await jitLaunch(withScript: nil, appName: appName, classicMode: classicMode)
    }

    func jitLaunch(withScript script: String, appName: String, classicMode: UInt) async {
        await jitLaunch(withScript: Optional(script), appName: appName, classicMode: classicMode)
    }

    func jitLaunch(withPID pid: Int, withScript script: String?, appName: String) async {
        await jitLaunch(withScript: script, appName: appName, classicMode: 0)
    }

    func showRunWhenMultitaskAlert() async -> Bool? {
        true
    }

    private func jitLaunch(withScript script: String?, appName: String, classicMode: UInt) async {
        let enabled = await LCUtils.askForJIT(withScript: script, appName: appName, classicMode: classicMode) { [weak self] message in
            Task { @MainActor in
                self?.errorMessage = message
            }
        }
        if enabled {
            LCSharedUtils.launchToGuestApp(withClassicMode: classicMode)
        }
    }
}

enum NativeSigningConfiguration {
    static func configureLiveContainerJIT(
        with assetStore: SigningAssetStore,
        certificatePassword: String
    ) throws {
        guard let certificate = assetStore.data(for: .certificate) else {
            throw NativeSigningConfigurationError.certificateMissing
        }
        guard !certificatePassword.isEmpty else {
            throw NativeSigningConfigurationError.passwordMissing
        }

        // LiveContainer reads this configuration when it invokes its native
        // JIT and signing path. The source files remain in Workspace storage.
        LCUtils.appGroupUserDefault.set(certificate, forKey: "LCCertificateData")
        LCUtils.appGroupUserDefault.set(certificatePassword, forKey: "LCCertificatePassword")
        UserDefaults.standard.set(certificatePassword, forKey: "LCCertificatePassword")
    }
}

private enum NativeSigningConfigurationError: LocalizedError {
    case certificateMissing
    case passwordMissing

    var errorDescription: String? {
        switch self {
        case .certificateMissing:
            return "Choose a .p12 or .pfx certificate first."
        case .passwordMissing:
            return "Enter the certificate password first."
        }
    }
}

struct NativeIPASignerView: View {
    @StateObject private var assetStore = SigningAssetStore()
    @StateObject private var packageStore = SigningPackageStore()
    @StateObject private var signer = NativeIPASigningEngine()
    @State private var showingPackageImporter = false
    @State private var showingCertificateImporter = false
    @State private var showingProfileImporter = false
    @State private var certificatePassword = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Package") {
                    Button {
                        showingPackageImporter = true
                    } label: {
                        LabeledContent(
                            "IPA",
                            value: packageStore.package?.originalName ?? "Choose an IPA from Files"
                        )
                    }
                    .buttonStyle(.plain)
                    if packageStore.package != nil {
                        Button("Remove selected IPA", role: .destructive) {
                            packageStore.removePackage()
                            signer.clearOutput()
                        }
                    }
                    Text("The selected IPA stays in IPA Signer storage. It is not installed in Workspace or LiveContainer.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("Signing assets") {
                    signingAssetRow(
                        kind: .certificate,
                        asset: assetStore.asset(for: .certificate),
                        importer: $showingCertificateImporter,
                        placeholder: "Choose .p12"
                    )
                    signingAssetRow(
                        kind: .provisioningProfile,
                        asset: assetStore.asset(for: .provisioningProfile),
                        importer: $showingProfileImporter,
                        placeholder: "Choose .mobileprovision"
                    )
                    SecureField("Certificate password", text: $certificatePassword)
                        .textContentType(.password)
                    Text("The profile is embedded in the selected IPA before signing. The password is used only for this signing operation and is not saved.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section {
                    Button(signer.isSigning ? "Signing..." : "Sign IPA") {
                        signer.sign(
                            packageURL: packageStore.packageURL,
                            certificate: assetStore.data(for: .certificate),
                            provisioningProfile: assetStore.data(for: .provisioningProfile),
                            certificatePassword: certificatePassword
                        )
                    }
                    .disabled(
                        signer.isSigning || packageStore.packageURL == nil ||
                        assetStore.asset(for: .certificate) == nil ||
                        assetStore.asset(for: .provisioningProfile) == nil || certificatePassword.isEmpty
                    )
                    .frame(minHeight: 44)
                    if signer.isSigning {
                        ProgressView(signer.statusMessage ?? "Signing IPA")
                    } else if let signedIPAURL = signer.signedIPAURL {
                        ShareLink(item: signedIPAURL) {
                            Label("Share signed IPA", systemImage: "square.and.arrow.up")
                        }
                    }
                    if let statusMessage = signer.statusMessage, !signer.isSigning {
                        Text(statusMessage)
                            .font(.footnote)
                            .foregroundStyle(signer.signedIPAURL == nil ? .red : .secondary)
                    }
                }
            }
            .navigationTitle("IPA Signer")
        }
        .fileImporter(
            isPresented: $showingPackageImporter,
            allowedContentTypes: [UTType(filenameExtension: "ipa") ?? .zip, .zip],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first {
                _ = packageStore.importPackage(from: url)
            }
        }
        .fileImporter(
            isPresented: $showingCertificateImporter,
            allowedContentTypes: SigningAssetKind.certificate.fileImporterContentTypes,
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first {
                _ = assetStore.importAsset(from: url, kind: .certificate)
            }
        }
        .fileImporter(
            isPresented: $showingProfileImporter,
            allowedContentTypes: SigningAssetKind.provisioningProfile.fileImporterContentTypes,
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first {
                _ = assetStore.importAsset(from: url, kind: .provisioningProfile)
            }
        }
    }

    @ViewBuilder
    private func signingAssetRow(
        kind: SigningAssetKind,
        asset: SigningAsset?,
        importer: Binding<Bool>,
        placeholder: String
    ) -> some View {
        HStack(spacing: 8) {
            Button { importer.wrappedValue = true } label: {
                LabeledContent(kind.label, value: asset?.originalName ?? placeholder)
            }
            .buttonStyle(.plain)
            if let asset {
                Button(role: .destructive) { assetStore.remove(asset) } label: {
                    Image(systemName: "trash")
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Remove \(kind.label)")
            }
        }
    }
}

@MainActor
final class NativeIPASigningEngine: ObservableObject {
    @Published private(set) var isSigning = false
    @Published private(set) var statusMessage: String?
    @Published private(set) var signedIPAURL: URL?

    func clearOutput() {
        signedIPAURL = nil
        statusMessage = nil
    }

    func sign(
        packageURL: URL?,
        certificate: Data?,
        provisioningProfile: Data?,
        certificatePassword: String
    ) {
        guard let packageURL, let certificate, let provisioningProfile else {
            statusMessage = "Choose an IPA, certificate, and provisioning profile first."
            return
        }
        guard !certificatePassword.isEmpty else {
            statusMessage = "Enter the certificate password first."
            return
        }

        isSigning = true
        statusMessage = "Preparing IPA..."
        signedIPAURL = nil

        Task {
            do {
                let output = try await Self.signIPA(
                    packageURL: packageURL,
                    certificate: certificate,
                    provisioningProfile: provisioningProfile,
                    certificatePassword: certificatePassword
                )
                signedIPAURL = output
                statusMessage = "Signed IPA is ready to share."
            } catch {
                statusMessage = "Signing failed: \(error.localizedDescription)"
            }
            isSigning = false
        }
    }

    private static func signIPA(
        packageURL: URL,
        certificate: Data,
        provisioningProfile: Data,
        certificatePassword: String
    ) async throws -> URL {
        let fileManager = FileManager.default
        let workRoot = fileManager.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("WorkspaceSigner", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let extractedRoot = workRoot.appendingPathComponent("Extracted", isDirectory: true)
        let payloadRoot = extractedRoot.appendingPathComponent("Payload", isDirectory: true)
        let outputRoot = workRoot.appendingPathComponent("Output", isDirectory: true)

        try fileManager.createDirectory(at: extractedRoot, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: workRoot) }

        let extractionProgress = Progress(totalUnitCount: 1)
        guard extract(packageURL.path, extractedRoot.path, extractionProgress) == 0 else {
            throw NativeIPASigningError.invalidIPA
        }
        guard let appURL = try fileManager.contentsOfDirectory(
            at: payloadRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ).first(where: { $0.pathExtension.lowercased() == "app" }) else {
            throw NativeIPASigningError.missingAppBundle
        }
        guard let info = NSDictionary(contentsOf: appURL.appendingPathComponent("Info.plist")) as? [String: Any],
              let bundleIdentifier = info["CFBundleIdentifier"] as? String,
              !bundleIdentifier.isEmpty else {
            throw NativeIPASigningError.missingBundleIdentifier
        }

        try provisioningProfile.write(to: appURL.appendingPathComponent("embedded.mobileprovision"), options: [.atomic])
        guard dlopen("@executable_path/Frameworks/ZSign.dylib", RTLD_NOW) != nil else {
            throw NativeIPASigningError.signerUnavailable
        }

        try await withCheckedThrowingContinuation { continuation in
            let progress = ZSigner.sign(
                withAppPath: appURL.path,
                bundleId: bundleIdentifier,
                cert: certificate,
                pass: certificatePassword
            ) { success, error in
                if success {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: error ?? NativeIPASigningError.signerFailed)
                }
            }
            if progress == nil {
                continuation.resume(throwing: NativeIPASigningError.signerUnavailable)
            }
        }

        try fileManager.createDirectory(at: outputRoot, withIntermediateDirectories: true)
        let outputPayload = outputRoot.appendingPathComponent("Payload", isDirectory: true)
        try fileManager.copyItem(at: payloadRoot, to: outputPayload)
        guard let archiveData = PKZipArchiver().zippedData(for: outputPayload.deletingLastPathComponent()) else {
            throw NativeIPASigningError.archiveFailed
        }

        let outputDirectory = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Signed IPAs", isDirectory: true)
        try fileManager.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let fileName = appURL.deletingPathExtension().lastPathComponent + "-signed.ipa"
        let outputURL = outputDirectory.appendingPathComponent(fileName, isDirectory: false)
        try? fileManager.removeItem(at: outputURL)
        try archiveData.write(to: outputURL, options: [.atomic])
        return outputURL
    }
}

private enum NativeIPASigningError: LocalizedError {
    case invalidIPA
    case missingAppBundle
    case missingBundleIdentifier
    case signerUnavailable
    case signerFailed
    case archiveFailed

    var errorDescription: String? {
        switch self {
        case .invalidIPA: return "The selected file is not a valid IPA archive."
        case .missingAppBundle: return "The IPA does not contain Payload/*.app."
        case .missingBundleIdentifier: return "The app bundle does not contain an identifier."
        case .signerUnavailable: return "The embedded signing engine could not be loaded."
        case .signerFailed: return "The signing engine did not complete the operation."
        case .archiveFailed: return "The signed IPA could not be packaged."
        }
    }
}
#endif
