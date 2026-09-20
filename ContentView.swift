import SwiftUI
import UIKit

struct ContentView: View {
    @ObservedObject var store: WorkspaceStore
    @State private var activeApp: VirtualApp?
    @State private var folder: VirtualFolder?
    @State private var showingOnboarding = false

    private var launcherApps: [VirtualApp] {
        // Workspace-owned tools always stay on the launcher. The native build
        // appends LiveContainer's installed guest apps below this grid.
        store.homeApps.filter { $0.isBuiltIn || $0.systemApp != nil }
    }

    private var launcherItemCount: Int {
#if LIVE_CONTAINER_NATIVE
        launcherApps.count + store.folders.count + DataManager.shared.model.apps.count
#else
        launcherApps.count + store.folders.count
#endif
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                WallpaperBackground(
                    choice: String(describing: store.settings.wallpaper),
                    imageURL: store.wallpaperURL
                )

                // The launcher itself does not scroll. Native guest apps are
                // rendered in the same fixed home surface as Workspace tools.
                VStack(alignment: .leading, spacing: 18) {
                    HomeHeader(itemCount: launcherItemCount)
                    Group {
                        HomeGrid(
                            apps: launcherApps,
                            folders: store.folders,
                            columns: store.settings.gridColumns,
                            showLabels: store.settings.showAppLabels,
                            onOpenApp: open,
                            onOpenFolder: { folder = $0 }
                        )
#if LIVE_CONTAINER_NATIVE
                        NativeLiveContainerHomeGrid(
                            columns: store.settings.gridColumns,
                            showLabels: store.settings.showAppLabels
                        )
#endif
                    }
                    .frame(maxHeight: max(0, proxy.size.height - 164), alignment: .top)
                    .clipped()
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, 8)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            WorkspaceDock(pinnedApps: store.pinnedApps, onOpenApp: open)
                .padding(.horizontal, 18)
                .padding(.bottom, 8)
        }
        .fullScreenCover(item: $activeApp) { app in
            RuntimeWindow(
                app: app,
                store: store,
                onOpen: open,
                onHome: { activeApp = nil }
            )
        }
        .sheet(item: $folder) { folder in
            FolderView(folder: folder, store: store, onOpen: open)
        }
        .fullScreenCover(isPresented: $showingOnboarding) {
            WorkspaceOnboardingView(store: store) {
                store.completeOnboarding()
                showingOnboarding = false
            }
        }
        .onAppear {
            showingOnboarding = store.needsOnboarding
        }
        .onChange(of: store.needsOnboarding) { _, needsOnboarding in
            if needsOnboarding { showingOnboarding = true }
        }
        .alert("Workspace problem", isPresented: Binding(
            get: { store.importError != nil },
            set: { if !$0 { store.importError = nil } }
        )) {
            Button("OK", role: .cancel) { store.importError = nil }
        } message: {
            Text(store.importError ?? "")
        }
    }

    private func open(_ app: VirtualApp) {
        store.open(app)
        folder = nil
        activeApp = app
    }
}

private struct HomeHeader: View {
    let itemCount: Int

    var body: some View {
        HStack(alignment: .lastTextBaseline) {
            Text("Home")
                .font(.largeTitle.weight(.bold))
            Spacer(minLength: 12)
            Text("\(itemCount) items")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .accessibilityAddTraits(.isHeader)
    }
}

private struct HomeGrid: View {
    let apps: [VirtualApp]
    let folders: [VirtualFolder]
    let columns: Int
    let showLabels: Bool
    let onOpenApp: (VirtualApp) -> Void
    let onOpenFolder: (VirtualFolder) -> Void

    private var gridColumns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 18), count: max(2, min(columns, 5)))
    }

    var body: some View {
        LazyVGrid(columns: gridColumns, alignment: .leading, spacing: 22) {
            ForEach(apps) { app in
                AppIconButton(app: app, showLabel: showLabels, action: { onOpenApp(app) })
            }
            ForEach(folders) { folder in
                FolderIconButton(folder: folder, showLabel: showLabels, action: { onOpenFolder(folder) })
            }
        }
    }
}

private struct AppIconButton: View {
    let app: VirtualApp
    let showLabel: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 7) {
                Image(systemName: app.iconSymbol)
                    .font(.system(size: 25, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 62, height: 62)
                    .background(Color.workspaceAccent(app.iconColor), in: RoundedRectangle(cornerRadius: 17, style: .continuous))
                    .shadow(color: .black.opacity(0.14), radius: 6, y: 3)
                if showLabel {
                    Text(app.displayName)
                        .font(.caption.weight(.medium))
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.primary)
                }
            }
            .frame(maxWidth: .infinity, minHeight: showLabel ? 91 : 62)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(app.displayName)
        .accessibilityHint(app.isBuiltIn ? "Opens app" : "Opens imported app status")
    }
}

private struct FolderIconButton: View {
    let folder: VirtualFolder
    let showLabel: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 7) {
                Image(systemName: folder.symbol)
                    .font(.system(size: 25, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 62, height: 62)
                    .background(.orange, in: RoundedRectangle(cornerRadius: 17, style: .continuous))
                if showLabel {
                    Text(folder.name)
                        .font(.caption.weight(.medium))
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.primary)
                }
            }
            .frame(maxWidth: .infinity, minHeight: showLabel ? 91 : 62)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Folder \(folder.name)")
    }
}

private struct WorkspaceDock: View {
    let pinnedApps: [VirtualApp]
    let onOpenApp: (VirtualApp) -> Void

    var body: some View {
        HStack(spacing: 14) {
            ForEach(pinnedApps.prefix(5)) { app in
                AppDockButton(app: app, action: { onOpenApp(app) })
            }
        }
        .padding(.horizontal, 15)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.24)))
    }
}

private struct AppDockButton: View {
    let app: VirtualApp
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: app.iconSymbol)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(Color.workspaceAccent(app.iconColor), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(app.displayName)
    }
}

struct RuntimeWindow: View {
    let app: VirtualApp
    @ObservedObject var store: WorkspaceStore
    let onOpen: (VirtualApp) -> Void
    let onHome: () -> Void

    var body: some View {
        GeometryReader { proxy in
            let isLandscape = proxy.size.width > proxy.size.height
            ZStack(alignment: isLandscape ? .leading : .trailing) {
                appContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(uiColor: .systemBackground))

                HomeBar(isLandscape: isLandscape, action: onHome)
            }
            .ignoresSafeArea()
        }
        .preferredColorScheme(nil)
    }

    @ViewBuilder
    private var appContent: some View {
        switch app.systemApp {
        case .helloWorld:
            BuiltInHelloWorldView()
        case .appLibrary:
            LiveContainerAppsView(store: store, onOpen: onOpen)
        case .ipaSigner:
            IPASignerView(store: store)
        case .installer:
            InstallerView(store: store, onOpen: onOpen)
        case .liveContainer:
            LiveContainerAppsView(store: store, onOpen: onOpen)
        case .liveContainerSettings:
            // Kept only so an app record from an older workspace build can
            // still open. New launchers expose these controls inside Settings.
            SettingsView(store: store)
        case .settings:
            SettingsView(store: store)
        case nil:
            ImportedRuntimeView(app: app, store: store)
        }
    }
}

private struct WallpaperBackground: View {
    let choice: String
    let imageURL: URL?

    private var normalizedChoice: String {
        choice.lowercased().replacingOccurrences(of: " ", with: "")
    }

    var body: some View {
        ZStack {
            if let imageURL, let image = UIImage(contentsOfFile: imageURL.path) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .overlay(.black.opacity(0.12))
            } else {
                switch normalizedChoice {
                case "aurora":
                    LinearGradient(
                        colors: [Color(red: 0.10, green: 0.33, blue: 0.38), Color(red: 0.18, green: 0.12, blue: 0.34)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                case "midnight":
                    LinearGradient(
                        colors: [Color(red: 0.02, green: 0.04, blue: 0.10), Color(red: 0.10, green: 0.16, blue: 0.28)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                case "ocean":
                    LinearGradient(
                        colors: [Color(red: 0.02, green: 0.23, blue: 0.38), Color(red: 0.06, green: 0.09, blue: 0.28)],
                        startPoint: .top,
                        endPoint: .bottomTrailing
                    )
                case "sunrise":
                    LinearGradient(
                        colors: [Color(red: 0.95, green: 0.37, blue: 0.25), Color(red: 0.40, green: 0.12, blue: 0.32)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                case "forest":
                    LinearGradient(
                        colors: [Color(red: 0.05, green: 0.27, blue: 0.22), Color(red: 0.02, green: 0.10, blue: 0.15)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                default:
                    Color(uiColor: .systemGroupedBackground)
                }
            }
        }
        .clipped()
        .ignoresSafeArea()
    }
}

private struct WorkspaceOnboardingView: View {
    @ObservedObject var store: WorkspaceStore
    let onFinish: () -> Void
    @State private var page = 0

    private let pageCount = 4

    var body: some View {
        ZStack {
            WallpaperBackground(
                choice: String(describing: store.settings.wallpaper),
                imageURL: store.wallpaperURL
            )

            VStack(spacing: 0) {
                HStack {
                    Text("Workspace setup")
                        .font(.headline)
                    Spacer()
                    Text("Step \(page + 1) of \(pageCount)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 24)
                .padding(.top, 18)

                TabView(selection: $page) {
                    OnboardingWelcomePage()
                        .tag(0)
                    OnboardingWallpaperPage(store: store)
                        .tag(1)
                    OnboardingJITPage(store: store)
                        .tag(2)
                    OnboardingReadyPage()
                        .tag(3)
                }
                .tabViewStyle(.page(indexDisplayMode: .always))

                Button(page == pageCount - 1 ? "Finish setup" : "Continue") {
                    if page == pageCount - 1 {
                        onFinish()
                    } else {
                        withAnimation(.easeInOut(duration: 0.25)) { page += 1 }
                    }
                }
                .font(.body.weight(.semibold))
                .frame(maxWidth: .infinity, minHeight: 50)
                .buttonStyle(.borderedProminent)
                .padding(.horizontal, 24)
                .padding(.bottom, 18)
            }
        }
        .interactiveDismissDisabled()
    }
}

private struct OnboardingWelcomePage: View {
    var body: some View {
        OnboardingPageLayout(
            symbol: "rectangle.3.group.fill",
            title: "Your private workspace",
            message: "Keep your launcher, LiveContainer apps, and setup tools together in one focused home screen. The host still needs a compatible developer certificate when you install it."
        )
    }
}

private struct OnboardingWallpaperPage: View {
    @ObservedObject var store: WorkspaceStore
    @State private var showingImporter = false

    var body: some View {
        OnboardingPageLayout(
            symbol: "photo.fill",
            title: "Choose a wallpaper",
            message: "Pick the backdrop you want to see each time Workspace opens. You can change it later in Settings."
        ) {
            Picker("Wallpaper", selection: $store.settings.wallpaper) {
                ForEach(WallpaperOption.allCases, id: \.self) { choice in
                    Text(Self.label(for: choice)).tag(choice)
                }
            }
            .pickerStyle(.menu)
            .onChange(of: store.settings) { _, _ in store.settingsDidChange() }
            if store.settings.wallpaper == .custom {
                Button {
                    showingImporter = true
                } label: {
                    Label("Choose photo", systemImage: "photo.on.rectangle")
                }
                .buttonStyle(.bordered)
            }
        }
        .fileImporter(
            isPresented: $showingImporter,
            allowedContentTypes: [.image],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first {
                _ = store.importWallpaper(from: url)
            }
        }
    }

    private static func label(for choice: WallpaperOption) -> String {
        String(describing: choice)
            .replacingOccurrences(of: "([a-z])([A-Z])", with: "$1 $2", options: .regularExpression)
            .capitalized
    }
}

private struct OnboardingJITPage: View {
    @ObservedObject var store: WorkspaceStore
    @StateObject private var assetStore = SigningAssetStore()
    @State private var showingCertificateImporter = false
    @State private var showingProfileImporter = false
    @State private var certificatePassword = ""
    @State private var certificateStatus: String?

    var body: some View {
        OnboardingPageLayout(
            symbol: "bolt.fill",
            title: "Set up JIT when you need it",
            message: "Choose the path you normally use for emulators and other apps that need Just-In-Time compilation. You can change it later in Settings."
        ) {
            Picker("JIT method", selection: $store.settings.jitProvider) {
                ForEach(JITProvider.allCases, id: \.self) { provider in
                    Text(Self.label(for: provider)).tag(provider)
                }
            }
            .pickerStyle(.wheel)
            .frame(height: 110)
            .onChange(of: store.settings) { _, _ in store.settingsDidChange() }
            if store.settings.jitProvider == .certificate {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Developer certificate setup")
                        .font(.subheadline.weight(.semibold))
                    Button {
                        showingCertificateImporter = true
                    } label: {
                        Label(
                            assetStore.asset(for: .certificate)?.originalName ?? "Choose .p12 certificate",
                            systemImage: "key.fill"
                        )
                    }
                    Button {
                        showingProfileImporter = true
                    } label: {
                        Label(
                            assetStore.asset(for: .provisioningProfile)?.originalName ?? "Choose .mobileprovision",
                            systemImage: "doc.badge.gearshape"
                        )
                    }
                    if assetStore.asset(for: .certificate) != nil {
                        SecureField("Certificate password", text: $certificatePassword)
                            .textContentType(.password)
                            .onChange(of: certificatePassword) { _, value in
                                WorkspaceCertificatePasswordStore.save(value)
                            }
                        #if LIVE_CONTAINER_NATIVE
                        Button("Use certificate for LiveContainer JIT") {
                            configureLiveContainerJIT()
                        }
                        .disabled(certificatePassword.isEmpty)
                        #endif
                    }
                    Text("These signing files are saved once and reused by IPA Signer. The certificate can also configure LiveContainer JIT.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Text("From Files, share both files to Workspace. They will appear here automatically.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    if let certificateStatus {
                        Text(certificateStatus)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else if let errorMessage = assetStore.errorMessage {
                        Text(errorMessage)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }
            } else if store.settings.jitProvider == .jitStreamer {
                Text("JIT Streamer can be configured later from Settings.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .fileImporter(
            isPresented: $showingCertificateImporter,
            allowedContentTypes: SigningAssetKind.certificate.fileImporterContentTypes,
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first,
                   assetStore.importAsset(from: url, kind: .certificate),
                   !certificatePassword.isEmpty {
                    configureLiveContainerJIT()
                }
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
                if let url = urls.first { assetStore.importAsset(from: url, kind: .provisioningProfile) }
            case .failure(let error):
                assetStore.errorMessage = error.localizedDescription
            }
        }
        .onAppear {
            if certificatePassword.isEmpty {
                certificatePassword = WorkspaceCertificatePasswordStore.load()
            }
        }
    }

    private static func label(for provider: JITProvider) -> String {
        String(describing: provider)
            .replacingOccurrences(of: "([a-z])([A-Z])", with: "$1 $2", options: .regularExpression)
            .capitalized
    }

    private func configureLiveContainerJIT() {
        #if LIVE_CONTAINER_NATIVE
        do {
            try NativeSigningConfiguration.configureLiveContainerJIT(
                with: assetStore,
                certificatePassword: certificatePassword
            )
            certificateStatus = "Certificate saved for LiveContainer JIT."
        } catch {
            certificateStatus = error.localizedDescription
        }
        #endif
    }
}

private struct OnboardingReadyPage: View {
    var body: some View {
        OnboardingPageLayout(
            symbol: "checkmark.circle.fill",
            title: "You are ready",
            message: "Use Installer to add repositories or import an IPA. LiveContainer-installed apps will appear on your home screen."
        )
    }
}

private struct OnboardingPageLayout<Content: View>: View {
    let symbol: String
    let title: String
    let message: String
    @ViewBuilder let content: () -> Content

    init(symbol: String, title: String, message: String, @ViewBuilder content: @escaping () -> Content = { EmptyView() }) {
        self.symbol = symbol
        self.title = title
        self.message = message
        self.content = content
    }

    var body: some View {
        VStack(spacing: 22) {
            Spacer()
            Image(systemName: symbol)
                .font(.system(size: 64, weight: .semibold))
                .foregroundStyle(.tint)
            Text(title)
                .font(.title.weight(.bold))
                .multilineTextAlignment(.center)
            Text(message)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 330)
            content()
            Spacer()
        }
        .padding(.horizontal, 32)
    }
}

private struct HomeBar: View {
    let isLandscape: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Capsule()
                .fill(.primary.opacity(0.45))
                .frame(width: 6, height: 76)
                .frame(width: 44, height: 128)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 6)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 10)
                .onEnded { value in
                    if value.translation.height < -20 || abs(value.translation.width) > 24 {
                        action()
                    }
                }
        )
        .accessibilityLabel("Return to Home")
        .accessibilityHint(isLandscape ? "Swipe or tap the left edge" : "Swipe or tap the right edge")
    }
}

private struct BuiltInHelloWorldView: View {
    @State private var didTap = false

    var body: some View {
        VStack(spacing: 28) {
            Spacer()
            Image(systemName: "hand.wave.fill")
                .font(.system(size: 72, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            VStack(spacing: 10) {
                Text("Hello, world!")
                    .font(.largeTitle.weight(.bold))
                Text(didTap ? "Thanks for saying hello." : "A small app with a big welcome.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            Button(didTap ? "Say hello again" : "Say hello") {
                withAnimation(.easeInOut(duration: 0.2)) { didTap.toggle() }
            }
            .font(.body.weight(.semibold))
            .frame(minWidth: 160, minHeight: 48)
            .buttonStyle(.borderedProminent)
            Spacer()
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(uiColor: .systemBackground))
    }
}

private struct ImportedRuntimeView: View {
    let app: VirtualApp
    @ObservedObject var store: WorkspaceStore

    private var report: LiveContainerRuntimeReport {
        LiveContainerRuntime.shared.inspect(ipaURL: store.ipaURL(for: app))
    }

    var body: some View {
        VStack(spacing: 18) {
            Spacer()
            Image(systemName: app.iconSymbol)
                .font(.system(size: 54, weight: .semibold))
                .foregroundStyle(Color.workspaceAccent(app.iconColor))
            Text(app.displayName)
                .font(.title.weight(.bold))
                .multilineTextAlignment(.center)
            Label(report.state.label, systemImage: report.canExecuteImportedIPA ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(report.canExecuteImportedIPA ? Color.green : Color.orange)
            Text(report.message)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 340)
            Text("The IPA is stored inside this app and remains available to the signing workflow.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
            Spacer()
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
