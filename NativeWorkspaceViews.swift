#if LIVE_CONTAINER_NATIVE
import SwiftUI
import UIKit

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
        Array(repeating: GridItem(.flexible(minimum: 74, maximum: 120), spacing: 16), count: max(2, min(columns, 5)))
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
                    .frame(maxWidth: .infinity, minHeight: showLabels ? 98 : 74)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(app.displayName)
                .accessibilityHint("Opens LiveContainer app")
                .contextMenu {
                    Button("Remove app", role: .destructive) {
                        launcher.remove(app)
                    }
                }
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
                try? await Task.sleep(nanoseconds: 350_000_000)
                WorkspaceGuestHomeOverlayController.shared.show()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func remove(_ app: LCAppModel) {
        let root = app.appInfo.isShared ? LCPath.lcGroupBundlePath : LCPath.bundlePath
        guard let relativePath = app.appInfo.relativeBundlePath else { return }
        let appURL = root.appendingPathComponent(relativePath, isDirectory: true)
        do {
            try FileManager.default.removeItem(at: appURL)
            DataManager.shared.model.apps.removeAll { $0 == app }
            DataManager.shared.model.hiddenApps.removeAll { $0 == app }
        } catch {
            errorMessage = "Could not remove \(app.displayName): \(error.localizedDescription)"
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

@MainActor
final class WorkspaceGuestHomeOverlayController {
    static let shared = WorkspaceGuestHomeOverlayController()
    private var window: UIWindow?

    func show() {
        guard window == nil else { return }
        let activeScenes = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .filter({ $0.activationState == .foregroundActive })
        guard let scene = activeScenes.first(where: { $0.session.configuration.name != "Main" }) ?? activeScenes.first else { return }
        let overlay = UIWindow(windowScene: scene)
        overlay.backgroundColor = .clear
        overlay.windowLevel = UIWindow.Level(rawValue: UIWindow.Level.statusBar.rawValue + 1)
        let session = scene.session
        overlay.rootViewController = UIHostingController(rootView: WorkspaceGuestHomeOverlay { [weak self] in
            self?.hide()
            UIApplication.shared.requestSceneSessionDestruction(session, options: nil)
        })
        overlay.isHidden = false
        window = overlay
    }

    func hide() {
        window?.isHidden = true
        window = nil
    }
}

private struct WorkspaceGuestHomeOverlay: View {
    let onHome: () -> Void

    var body: some View {
        GeometryReader { proxy in
            let landscape = proxy.size.width > proxy.size.height
            HStack {
                if landscape { homeButton }
                Spacer(minLength: 0)
                if !landscape { homeButton }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.vertical, 24)
            .padding(landscape ? .leading : .trailing, 6)
        }
        .ignoresSafeArea()
    }

    private var homeButton: some View {
        Button(action: onHome) {
            Capsule().fill(.primary.opacity(0.78)).frame(width: 6, height: 92)
        }
        .frame(width: 44, height: 120)
        .contentShape(Rectangle())
        .buttonStyle(.plain)
        .accessibilityLabel("Return to Workspace home")
        .accessibilityHint("Closes the LiveContainer app window")
    }
}

@MainActor
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

        WorkspaceCertificatePasswordStore.save(certificatePassword)

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
    @State private var showingInstallHandoff = false
    @State private var certificatePassword = ""
    @StateObject private var localServer = LocalInstallServer()

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
                    Text("The selected IPA stays in protected Workspace storage until you export the signed result.")
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
                        .onChange(of: certificatePassword) { _, value in
                            WorkspaceCertificatePasswordStore.save(value)
                        }
                    Text("The profile is embedded in the selected IPA before signing. The password is stored locally and reused for future signing and JIT setup.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Text("You can share the certificate and profile from Files to Workspace instead of browsing for them here.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    if let errorMessage = assetStore.errorMessage {
                        Text(errorMessage)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }

                Section {
                    Button(signer.isSigning ? "Signing..." : "Sign and export IPA") {
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
                        Button {
                            showingInstallHandoff = true
                        } label: {
                            Label("Install on device Home Screen", systemImage: "iphone.and.arrow.forward")
                        }
                        Button {
                            startLocalInstallServer(for: signedIPAURL, info: signer.signedAppInfo)
                        } label: {
                            Label(localServer.isRunning ? "Refresh phone installer" : "Start phone installer", systemImage: "network")
                        }
                        if let installURL = localServer.installURL {
                            Button {
                                openLocalInstallPage(installURL)
                            } label: {
                                Label("Open local installer", systemImage: "arrow.up.forward.app")
                            }
                            if let otaURL = localServer.otaURL {
                                Button {
                                    openSystemInstaller(otaURL)
                                } label: {
                                    Label("Open iOS Home Screen installer", systemImage: "iphone.and.arrow.forward")
                                }
                            }
                            ShareLink(item: installURL) {
                                Label("Share local install link", systemImage: "link")
                            }
                            Text(localServer.statusMessage ?? installURL.absoluteString)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                    if let statusMessage = signer.statusMessage, !signer.isSigning {
                        Text(statusMessage)
                            .font(.footnote)
                            .foregroundStyle(signer.signedIPAURL == nil ? .red : .secondary)
                    }
                }
            }
            .navigationTitle("Signing")
        }
        .onDisappear { localServer.stop() }
        .onAppear {
            if certificatePassword.isEmpty {
                certificatePassword = WorkspaceCertificatePasswordStore.load()
            }
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
            switch result {
            case .success(let urls):
                if let url = urls.first { _ = assetStore.importAsset(from: url, kind: .certificate) }
            case .failure(let error):
                assetStore.errorMessage = error.localizedDescription
            }
        }
        .fileImporter(
            isPresented: $showingProfileImporter,
            allowedContentTypes: SigningAssetKind.provisioningProfile.fileImporterContentTypes,
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first { _ = assetStore.importAsset(from: url, kind: .provisioningProfile) }
            case .failure(let error):
                assetStore.errorMessage = error.localizedDescription
            }
        }
        .sheet(isPresented: $showingInstallHandoff) {
            if let signedIPAURL = signer.signedIPAURL {
                WorkspaceInstallHandoffView(ipaURL: signedIPAURL)
            }
        }
    }

    private func startLocalInstallServer(for url: URL, info: SignedAppInstallInfo?) {
        localServer.start(packageURL: url, appInfo: info ?? SignedAppInstallInfo(
            bundleIdentifier: "com.pkp107.workspace.signed",
            version: "1.0",
            displayName: url.deletingPathExtension().lastPathComponent
        ))
    }

    private func openLocalInstallPage(_ url: URL) {
        UIApplication.shared.open(url) { accepted in
            if !accepted {
                localServer.reportStatus("iOS could not open the local installer page. Try the external HTTPS or SideStore handoff.")
            }
        }
    }

    private func openSystemInstaller(_ url: URL) {
        UIApplication.shared.open(url) { accepted in
            if accepted {
                localServer.reportStatus("The iOS installer was opened. Confirm the install prompt to place the app on your Home Screen.")
            } else {
                localServer.reportStatus("iOS could not open the Home Screen installer. Use the HTTPS or SideStore handoff.")
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

struct WorkspaceInstallHandoffView: View {
    let ipaURL: URL
    @Environment(\.dismiss) private var dismiss
    @State private var hostedIPAURL = ""
    @State private var hostedManifestURL = ""
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("SideStore") {
                    Text("Host the signed IPA at an HTTPS URL, then send it to SideStore. SideStore performs the device installation and the icon appears on the physical Home Screen.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    TextField("https://example.com/App.ipa", text: $hostedIPAURL)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        .autocorrectionDisabled()
                    Button("Open in SideStore") {
                        openSideStore()
                    }
                    .disabled(!isHTTPS(hostedIPAURL))
                }

                Section("Apple OTA installation") {
                    Text("Host an install-manifest.plist over HTTPS. iOS will show its installation confirmation and place the app on the Home Screen when the profile is valid for this device.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    TextField("https://example.com/manifest.plist", text: $hostedManifestURL)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        .autocorrectionDisabled()
                    Button("Open OTA installer") {
                        openOTA()
                    }
                    .disabled(!isHTTPS(hostedManifestURL))
                }

                Section("Local transfer") {
                    ShareLink(item: ipaURL) {
                        Label("Share signed IPA", systemImage: "square.and.arrow.up")
                    }
                    Text("Use LocalSend, Files, FlekStore, AltStore, or another installer when the IPA is only stored on this phone.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage).foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Install on Home Screen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func isHTTPS(_ value: String) -> Bool {
        guard let url = URL(string: value.trimmingCharacters(in: .whitespacesAndNewlines)) else { return false }
        return url.scheme?.lowercased() == "https" && url.host != nil
    }

    private func openSideStore() {
        guard isHTTPS(hostedIPAURL), let encoded = hostedIPAURL.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "sidestore://install?url=\(encoded)") else {
            errorMessage = "Enter a valid HTTPS IPA URL."
            return
        }
        UIApplication.shared.open(url) { accepted in
            if !accepted { errorMessage = "SideStore is not installed or its URL scheme is unavailable." }
        }
    }

    private func openOTA() {
        guard isHTTPS(hostedManifestURL), let encoded = hostedManifestURL.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "itms-services://?action=download-manifest&url=\(encoded)") else {
            errorMessage = "Enter a valid HTTPS manifest URL."
            return
        }
        UIApplication.shared.open(url) { accepted in
            if !accepted { errorMessage = "iOS could not open the OTA installation link." }
        }
    }
}

@MainActor
final class NativeIPASigningEngine: ObservableObject {
    @Published private(set) var isSigning = false
    @Published private(set) var statusMessage: String?
    @Published private(set) var signedIPAURL: URL?
    @Published private(set) var signedAppInfo: SignedAppInstallInfo?

    func clearOutput() {
        signedIPAURL = nil
        signedAppInfo = nil
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
                signedIPAURL = output.url
                signedAppInfo = output.info
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
    ) async throws -> (url: URL, info: SignedAppInstallInfo) {
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
        try await withCheckedThrowingContinuation { continuation in
            LCUtils.workspaceSignApp(
                atPath: appURL.path,
                bundleIdentifier: bundleIdentifier,
                certificate: certificate,
                password: certificatePassword
            ) { success, error in
                if success {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: error ?? NativeIPASigningError.signerFailed)
                }
            }
        }

        try fileManager.createDirectory(at: outputRoot, withIntermediateDirectories: true)
        let outputPayload = outputRoot.appendingPathComponent("Payload", isDirectory: true)
        try fileManager.copyItem(at: payloadRoot, to: outputPayload)
        guard let archiveData = LCUtils.workspaceZipDirectory(at: outputPayload.deletingLastPathComponent()) else {
            throw NativeIPASigningError.archiveFailed
        }

        let outputDirectory = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Workspace Files", isDirectory: true)
            .appendingPathComponent("Signed", isDirectory: true)
        try fileManager.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let fileName = appURL.deletingPathExtension().lastPathComponent + "-signed.ipa"
        let outputURL = outputDirectory.appendingPathComponent(fileName, isDirectory: false)
        try? fileManager.removeItem(at: outputURL)
        try archiveData.write(to: outputURL, options: [.atomic])
        return (outputURL, SignedAppInstallInfo(
            bundleIdentifier: bundleIdentifier,
            version: info["CFBundleShortVersionString"] as? String ?? "1.0",
            displayName: info["CFBundleDisplayName"] as? String ?? info["CFBundleName"] as? String ?? appURL.deletingPathExtension().lastPathComponent
        ))
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
