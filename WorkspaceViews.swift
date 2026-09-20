import Foundation
import SwiftUI
import UniformTypeIdentifiers

/// Compatibility wrapper for the launcher entry named Installer. The native
/// build swaps the underlying surface for LiveContainer's real importer.
struct InstallerView: View {
    @ObservedObject var store: WorkspaceStore
    let onOpen: (VirtualApp) -> Void

    var body: some View {
        AppStoreInstallerView(store: store, onOpen: onOpen)
    }
}

private enum InstallerSection: String, CaseIterable, Identifiable {
    case store
    case repositories
    case installed

    var id: String { rawValue }

    var title: String {
        switch self {
        case .store: return "Store"
        case .repositories: return "Repos"
        case .installed: return "Installed"
        }
    }

    var symbol: String {
        switch self {
        case .store: return "bag.fill"
        case .repositories: return "server.rack"
        case .installed: return "square.stack.3d.up.fill"
        }
    }
}

private struct AppStoreInstallerView: View {
    @ObservedObject var store: WorkspaceStore
    let onOpen: (VirtualApp) -> Void
    @StateObject private var catalog = InstallerCatalog()
    @State private var section = InstallerSection.store
    @State private var selectedApp: CatalogApp?

    var body: some View {
        TabView(selection: $section) {
            InstallerCatalogView(catalog: catalog, store: store) { app in
                selectedApp = app
            }
            .tabItem { Label(InstallerSection.store.title, systemImage: InstallerSection.store.symbol) }
            .tag(InstallerSection.store)

            InstallerRepositoriesView(catalog: catalog)
                .tabItem { Label(InstallerSection.repositories.title, systemImage: InstallerSection.repositories.symbol) }
                .tag(InstallerSection.repositories)

            InstallerInstalledView(store: store, onOpen: onOpen)
                .tabItem { Label(InstallerSection.installed.title, systemImage: InstallerSection.installed.symbol) }
                .tag(InstallerSection.installed)
        }
        .tint(.orange)
        .task { await catalog.seedAndRefresh() }
        .sheet(item: $selectedApp) { app in
            InstallerInstallChoiceView(app: app, catalog: catalog, store: store)
        }
    }
}

private enum InstallerSort: String, CaseIterable, Identifiable {
    case alphabetical
    case category
    case newest

    var id: String { rawValue }
    var title: String {
        switch self {
        case .alphabetical: return "A-Z"
        case .category: return "Category"
        case .newest: return "Newest"
        }
    }
}

private struct InstallerCatalogView: View {
    @ObservedObject var catalog: InstallerCatalog
    @ObservedObject var store: WorkspaceStore
    let onInstall: (CatalogApp) -> Void
    @State private var searchText = ""
    @State private var sort = InstallerSort.alphabetical
    @State private var showingIPAImporter = false

    private var visibleApps: [CatalogApp] {
        let filtered = catalog.apps.filter { app in
            searchText.isEmpty || app.name.localizedCaseInsensitiveContains(searchText) ||
            app.developer.localizedCaseInsensitiveContains(searchText) ||
            app.category.localizedCaseInsensitiveContains(searchText)
        }
        switch sort {
        case .alphabetical:
            return filtered.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        case .category:
            return filtered.sorted {
                let categoryOrder = $0.category.localizedCaseInsensitiveCompare($1.category)
                if categoryOrder == .orderedSame {
                    return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
                }
                return categoryOrder == .orderedAscending
            }
        case .newest:
            return filtered.sorted { $0.version.localizedStandardCompare($1.version) == .orderedDescending }
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 14) {
                        Image(systemName: "bag.fill")
                            .font(.title2.weight(.semibold))
                            .foregroundStyle(.white)
                            .frame(width: 52, height: 52)
                            .background(.orange, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Workspace Store")
                                .font(.title3.weight(.bold))
                            Text("Discover apps from your repositories")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 8)
                }
                .listRowBackground(Color.clear)

                if visibleApps.isEmpty {
                    ContentUnavailableView(
                        searchText.isEmpty ? "No apps yet" : "No matching apps",
                        systemImage: searchText.isEmpty ? "bag" : "magnifyingglass",
                        description: Text(searchText.isEmpty ? "Refresh a repository from Repos to build your catalog." : "Try a different search.")
                    )
                } else {
                    ForEach(visibleApps) { app in
                        InstallerCatalogRow(app: app, isDownloading: catalog.downloadingIDs.contains(app.id)) {
                            onInstall(app)
                        }
                    }
                }
            }
            .listStyle(.plain)
            .navigationTitle("Store")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            showingIPAImporter = true
                        } label: {
                            Label("Import IPA", systemImage: "square.and.arrow.down")
                        }
                        Divider()
                        Picker("Sort", selection: $sort) {
                            ForEach(InstallerSort.allCases) { option in
                                Text(option.title).tag(option)
                            }
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .accessibilityLabel("Store actions")
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("Search apps", text: $searchText)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    if !searchText.isEmpty {
                        Button { searchText = "" } label: {
                            Image(systemName: "xmark.circle.fill")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
                .background(.bar)
            }
            .fileImporter(isPresented: $showingIPAImporter, allowedContentTypes: [.item], allowsMultipleSelection: false) { result in
                switch result {
                case .success(let urls):
                    guard let url = urls.first else { return }
                    guard ["ipa", "tipa", "zip"].contains(url.pathExtension.lowercased()) else {
                        store.importError = "Choose an IPA file."
                        return
                    }
                    guard let copied = store.copyToWorkspaceFiles(from: url) else { return }
                    store.installerImportIPA(from: copied)
                case .failure(let error):
                    store.importError = error.localizedDescription
                }
            }
        }
    }
}

private struct InstallerCatalogRow: View {
    let app: CatalogApp
    let isDownloading: Bool
    let action: () -> Void

    var body: some View {
        HStack(spacing: 13) {
            Image(systemName: "app.fill")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 52, height: 52)
                .background(.orange, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(app.name).font(.body.weight(.semibold)).lineLimit(1)
                Text("\(app.developer) · \(app.category)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text("Version \(app.version)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 8)
            Button(isDownloading ? "Preparing" : "Get", action: action)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(isDownloading)
        }
        .padding(.vertical, 5)
    }
}

private struct InstallerRepositoriesView: View {
    @ObservedObject var catalog: InstallerCatalog
    @State private var showingAddSource = false
    @State private var sourceURL = ""

    var body: some View {
        NavigationStack {
            List {
                if catalog.sources.isEmpty {
                    ContentUnavailableView("No repositories", systemImage: "server.rack", description: Text("Add an AltStore, SideStore, eSign, or KSign-compatible feed."))
                } else {
                    ForEach(catalog.sources) { source in
                        HStack(spacing: 12) {
                            Image(systemName: "server.rack")
                                .foregroundStyle(.white)
                                .frame(width: 42, height: 42)
                                .background(.indigo, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                            VStack(alignment: .leading, spacing: 3) {
                                Text(source.name).font(.body.weight(.semibold))
                                Text("\(source.apps.count) apps · \(source.status)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button { catalog.refresh(source) } label: {
                                Image(systemName: "arrow.clockwise")
                            }
                            .disabled(catalog.loadingSourceIDs.contains(source.id))
                        }
                        .padding(.vertical, 4)
                    }
                    .onDelete { catalog.remove(at: $0) }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Repositories")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showingAddSource = true } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("Add repository")
                }
            }
            .alert("Add repository", isPresented: $showingAddSource) {
                TextField("https://example.com/apps.json", text: $sourceURL)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                Button("Add") {
                    catalog.addSource(sourceURL)
                    sourceURL = ""
                }
                Button("Cancel", role: .cancel) { sourceURL = "" }
            } message: {
                Text("Use an HTTPS AltStore, SideStore, eSign, or KSign-compatible JSON feed.")
            }
        }
    }
}

private struct InstallerInstalledView: View {
    @ObservedObject var store: WorkspaceStore
    let onOpen: (VirtualApp) -> Void

    var body: some View {
        NavigationStack {
#if LIVE_CONTAINER_NATIVE
            NativeLiveContainerAppLibraryView()
                .navigationTitle("Installed")
#else
            InstalledAppsView(store: store, onOpen: onOpen)
                .navigationTitle("Installed")
#endif
        }
    }
}

private enum InstallMode: String, CaseIterable, Identifiable {
    case liveContainer
    case sign
    var id: String { rawValue }
    var title: String {
        switch self {
        case .liveContainer: return "LiveContainer"
        case .sign: return "Sign and install"
        }
    }
}

private struct InstallerInstallChoiceView: View {
    let app: CatalogApp
    @ObservedObject var catalog: InstallerCatalog
    @ObservedObject var store: WorkspaceStore
    @Environment(\.dismiss) private var dismiss
    @StateObject private var assetStore = SigningAssetStore()
    @State private var mode = InstallMode.liveContainer
    @State private var certificatePassword = ""
    @State private var showingCertificateImporter = false
    @State private var showingProfileImporter = false
    @State private var isWorking = false
    @State private var statusMessage: String?
#if LIVE_CONTAINER_NATIVE
    @StateObject private var signer = NativeIPASigningEngine()
#endif

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    HStack(spacing: 14) {
                        Image(systemName: "app.fill")
                            .font(.title2.weight(.semibold))
                            .foregroundStyle(.white)
                            .frame(width: 62, height: 62)
                            .background(.orange, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        VStack(alignment: .leading, spacing: 4) {
                            Text(app.name).font(.title3.weight(.bold))
                            Text("\(app.developer) · \(app.version)")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Picker("Install method", selection: $mode) {
                        ForEach(InstallMode.allCases) { option in
                            Text(option.title).tag(option)
                        }
                    }
                    .pickerStyle(.segmented)

                    if mode == .liveContainer {
                        Label("The app will be installed into LiveContainer and appear on the Workspace home screen.", systemImage: "shippingbox.and.arrow.backward.fill")
                            .font(.body)
                            .foregroundStyle(.secondary)
                    } else {
                        signingOptions
                    }

                    if let statusMessage {
                        Text(statusMessage)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(20)
            }
            .navigationTitle("Install")
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                Button {
                    install()
                } label: {
                    HStack {
                        if isWorking { ProgressView().tint(.white) }
                        Text(mode == .sign ? "Sign and install" : "Install with LiveContainer")
                            .font(.body.weight(.semibold))
                    }
                    .frame(maxWidth: .infinity, minHeight: 50)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(isWorking || (mode == .sign && !signingReady))
                .padding(.horizontal, 18)
                .padding(.vertical, 10)
                .background(.bar)
            }
            .fileImporter(isPresented: $showingCertificateImporter, allowedContentTypes: SigningAssetKind.certificate.fileImporterContentTypes, allowsMultipleSelection: false) { result in
                if case .success(let urls) = result, let url = urls.first { _ = assetStore.importAsset(from: url, kind: .certificate) }
            }
            .fileImporter(isPresented: $showingProfileImporter, allowedContentTypes: SigningAssetKind.provisioningProfile.fileImporterContentTypes, allowsMultipleSelection: false) { result in
                if case .success(let urls) = result, let url = urls.first { _ = assetStore.importAsset(from: url, kind: .provisioningProfile) }
            }
            .onAppear { certificatePassword = WorkspaceCertificatePasswordStore.load() }
#if LIVE_CONTAINER_NATIVE
            .onChange(of: signer.signedIPAURL) { _, url in
                guard let url else { return }
                NativeWorkspaceInstaller.shared.install(url: url)
                statusMessage = "Signed app installed into LiveContainer."
                isWorking = false
                dismiss()
            }
#endif
        }
    }

    private var signingReady: Bool {
        assetStore.asset(for: .certificate) != nil &&
        assetStore.asset(for: .provisioningProfile) != nil &&
        !certificatePassword.isEmpty
    }

    @ViewBuilder
    private var signingOptions: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Signing options").font(.headline)
            Button { showingCertificateImporter = true } label: {
                Label(assetStore.asset(for: .certificate)?.originalName ?? "Choose certificate (.p12 or .pfx)", systemImage: "key.fill")
            }
            Button { showingProfileImporter = true } label: {
                Label(assetStore.asset(for: .provisioningProfile)?.originalName ?? "Choose provisioning profile", systemImage: "doc.badge.gearshape")
            }
            SecureField("Certificate password", text: $certificatePassword)
                .textContentType(.password)
                .onChange(of: certificatePassword) { _, value in WorkspaceCertificatePasswordStore.save(value) }
            Text("The signed app is also installed into LiveContainer after signing.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private func install() {
        isWorking = true
        statusMessage = "Downloading \(app.name)…"
        Task { @MainActor in
            do {
                let ipaURL = try await catalog.fetchIPA(app, store: store)
                if mode == .liveContainer {
                    store.installerImportIPA(from: ipaURL)
                    statusMessage = "Installed into LiveContainer."
                    isWorking = false
                    dismiss()
                } else {
#if LIVE_CONTAINER_NATIVE
                    signer.sign(
                        packageURL: ipaURL,
                        certificate: assetStore.data(for: .certificate),
                        provisioningProfile: assetStore.data(for: .provisioningProfile),
                        certificatePassword: certificatePassword
                    )
                    statusMessage = "Signing \(app.name)…"
#else
                    statusMessage = "Signing is available in the integrated Workspace build."
                    isWorking = false
#endif
                }
            } catch {
                statusMessage = error.localizedDescription
                isWorking = false
            }
        }
    }
}

/// The app-owned file system is a separate utility so Installer can stay a
/// catalog and installation workflow rather than becoming a settings screen.
struct WorkspaceFileManagerView: View {
    @ObservedObject var store: WorkspaceStore
    @State private var showingImporter = false
    @StateObject private var assetStore = SigningAssetStore()

    private let folders = ["Incoming", "IPAs", "Certificates", "Provisioning Profiles", "Downloads", "Signed"]

    var body: some View {
        NavigationStack {
            List {
                Section("Workspace storage") {
                    ForEach(folders, id: \.self) { folder in
                        NavigationLink {
                            WorkspaceFolderView(folder: folder, store: store)
                        } label: {
                            Label(folder, systemImage: folder == "Certificates" ? "key.fill" : "folder.fill")
                        }
                    }
                }
                Section("All files") {
                    let files = store.workspaceFiles()
                    if files.isEmpty {
                        ContentUnavailableView("No files", systemImage: "folder", description: Text("Import a file or copy one into Workspace Files from the Files app."))
                    } else {
                        ForEach(files, id: \.path) { file in
                            WorkspaceFileRow(file: file, onUse: {
                                use(file)
                            }) {
                                store.deleteWorkspaceFile(file)
                            }
                        }
                        .onDelete { offsets in
                            offsets.compactMap { files.indices.contains($0) ? files[$0] : nil }.forEach(store.deleteWorkspaceFile)
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("File Manager")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showingImporter = true } label: { Image(systemName: "plus") }
                        .accessibilityLabel("Import file")
                }
            }
            .fileImporter(isPresented: $showingImporter, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
                switch result {
                case .success(let urls): urls.forEach { _ = store.copyToWorkspaceFiles(from: $0) }
                case .failure(let error): store.importError = error.localizedDescription
                }
            }
        }
    }

    private func use(_ file: URL) {
        switch file.pathExtension.lowercased() {
        case "ipa", "tipa", "zip":
            store.installerImportIPA(from: file)
        case "p12", "pfx":
            if !assetStore.importAsset(from: file, kind: .certificate) {
                store.importError = assetStore.errorMessage
            }
        case "mobileprovision", "provisionprofile":
            if !assetStore.importAsset(from: file, kind: .provisioningProfile) {
                store.importError = assetStore.errorMessage
            }
        default:
            store.importError = "This file type is stored for sharing only."
        }
    }
}

private struct WorkspaceFolderView: View {
    let folder: String
    @ObservedObject var store: WorkspaceStore
    @StateObject private var assetStore = SigningAssetStore()

    private var files: [URL] {
        store.workspaceFiles().filter { $0.deletingLastPathComponent().lastPathComponent == folder }
    }

    var body: some View {
        List {
            if files.isEmpty {
                ContentUnavailableView("Folder is empty", systemImage: "folder", description: Text("Add files from File Manager or the Files app."))
            } else {
                ForEach(files, id: \.path) { file in
                    WorkspaceFileRow(file: file, onUse: { use(file) }) {
                        store.deleteWorkspaceFile(file)
                    }
                }
                .onDelete { offsets in offsets.compactMap { files.indices.contains($0) ? files[$0] : nil }.forEach(store.deleteWorkspaceFile) }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(folder)
    }

    private func use(_ file: URL) {
        switch file.pathExtension.lowercased() {
        case "ipa", "tipa", "zip":
            store.installerImportIPA(from: file)
        case "p12", "pfx":
            if !assetStore.importAsset(from: file, kind: .certificate) {
                store.importError = assetStore.errorMessage
            }
        case "mobileprovision", "provisionprofile":
            if !assetStore.importAsset(from: file, kind: .provisioningProfile) {
                store.importError = assetStore.errorMessage
            }
        default:
            store.importError = "This file type is stored for sharing only."
        }
    }
}

private struct WorkspaceFileRow: View {
    let file: URL
    let onUse: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(.white)
                .frame(width: 40, height: 40)
                .background(.teal, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(file.lastPathComponent).lineLimit(1)
                Text(file.deletingLastPathComponent().lastPathComponent).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if isUsable {
                Button("Use", action: onUse)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
            ShareLink(item: file) { Image(systemName: "square.and.arrow.up") }
                .frame(width: 44, height: 44)
                .accessibilityLabel("Share \(file.lastPathComponent)")
        }
        .contextMenu {
            if isUsable {
                Button("Use", action: onUse)
            }
            ShareLink(item: file) { Label("Share", systemImage: "square.and.arrow.up") }
            Button("Delete", role: .destructive, action: onDelete)
        }
    }

    private var isUsable: Bool {
        ["ipa", "tipa", "zip", "p12", "pfx", "mobileprovision", "provisionprofile"]
            .contains(file.pathExtension.lowercased())
    }

    private var icon: String {
        switch file.pathExtension.lowercased() {
        case "ipa", "tipa", "zip": return "shippingbox.fill"
        case "p12", "pfx": return "key.fill"
        case "mobileprovision", "provisionprofile": return "doc.badge.gearshape"
        default: return "doc.fill"
        }
    }
}

private struct CombinedInstallerView: View {
    @ObservedObject var store: WorkspaceStore
    let onOpen: (VirtualApp) -> Void
    @State private var tab = InstallerTab.files

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Installer section", selection: $tab) {
                    ForEach(InstallerTab.allCases) { tab in
                        Text(tab.label).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)

                switch tab {
                case .files:
                    InstallerFilesView(store: store, onOpen: onOpen)
                case .store:
                    InstallerStoreView(store: store)
                case .signing:
#if LIVE_CONTAINER_NATIVE
                    NativeIPASignerView()
#else
                    IPASignerView(store: store)
#endif
                }
            }
            .navigationTitle("Installer")
        }
    }
}

private enum InstallerTab: String, CaseIterable, Identifiable {
    case files
    case store
    case signing

    var id: String { rawValue }
    var label: String {
        switch self {
        case .files: return "Files"
        case .store: return "Store"
        case .signing: return "Signing"
        }
    }
}

private struct InstallerFilesView: View {
    @ObservedObject var store: WorkspaceStore
    let onOpen: (VirtualApp) -> Void
    @State private var showingImporter = false
    @StateObject private var assetStore = SigningAssetStore()
#if LIVE_CONTAINER_NATIVE
    @ObservedObject private var nativeInstaller = NativeWorkspaceInstaller.shared
#endif

    private var files: [URL] { store.workspaceFiles() }

    var body: some View {
        List {
            Section {
                Button {
                    showingImporter = true
                } label: {
                    Label("Copy from Files", systemImage: "square.and.arrow.down")
                }
                Text("Place IPAs, certificates, and provisioning profiles in Workspace Files. Select them here for installation or signing.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
#if LIVE_CONTAINER_NATIVE
                if nativeInstaller.isInstalling {
                    ProgressView("Installing in LiveContainer", value: nativeInstaller.progress, total: 1)
                }
                if let message = nativeInstaller.errorMessage {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
#endif
            } header: {
                Label("Workspace Files", systemImage: "folder.fill")
            }

            Section("Available files") {
                if files.isEmpty {
                    ContentUnavailableView("Folder is empty", systemImage: "folder", description: Text("Copy an IPA, .p12, or .mobileprovision from Files."))
                } else {
                    ForEach(files, id: \.path) { file in
                        InstallerFileRow(file: file) {
                            select(file)
                        } onDelete: {
                            store.deleteWorkspaceFile(file)
                        }
                    }
                    .onDelete { offsets in
                        offsets.compactMap { files.indices.contains($0) ? files[$0] : nil }
                            .forEach(store.deleteWorkspaceFile)
                    }
                }
            }

            Section("Installed guests") {
                NavigationLink {
                    LiveContainerAppsView(store: store, onOpen: onOpen)
                } label: {
                    Label("LiveContainer apps", systemImage: "shippingbox.and.arrow.backward.fill")
                }
                Text("Apps installed through the native runtime appear in the LiveContainer menu entry and can also be launched from Home.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .listStyle(.insetGrouped)
        .fileImporter(
            isPresented: $showingImporter,
            allowedContentTypes: [.item],
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case .success(let urls):
                urls.forEach { _ = store.copyToWorkspaceFiles(from: $0) }
            case .failure(let error):
                store.importError = error.localizedDescription
            }
        }
        .alert("Installer", isPresented: Binding(
            get: { store.importError != nil },
            set: { if !$0 { store.importError = nil } }
        )) {
            Button("OK", role: .cancel) { store.importError = nil }
        } message: {
            Text(store.importError ?? "")
        }
    }

    private func select(_ file: URL) {
        switch file.pathExtension.lowercased() {
        case "ipa", "zip":
            store.installerImportIPA(from: file)
        case "p12", "pfx":
            if !assetStore.importAsset(from: file, kind: .certificate) {
                store.importError = assetStore.errorMessage
            }
        case "mobileprovision", "provisionprofile":
            if !assetStore.importAsset(from: file, kind: .provisioningProfile) {
                store.importError = assetStore.errorMessage
            }
        default:
            store.importError = "Select an IPA, certificate, or provisioning profile."
        }
    }
}

private struct InstallerFileRow: View {
    let file: URL
    let onSelect: () -> Void
    let onDelete: () -> Void

    private var kind: String {
        switch file.pathExtension.lowercased() {
        case "ipa", "zip": return "IPA"
        case "p12", "pfx": return "Certificate"
        case "mobileprovision", "provisionprofile": return "Provisioning profile"
        default: return "File"
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.headline)
                .foregroundStyle(.white)
                .frame(width: 40, height: 40)
                .background(Color.orange, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(file.lastPathComponent)
                    .font(.body.weight(.semibold))
                    .lineLimit(1)
                Text(kind)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Select", action: onSelect)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        }
        .contextMenu {
            Button("Select", action: onSelect)
            Button("Delete", role: .destructive, action: onDelete)
        }
    }

    private var icon: String {
        switch kind {
        case "IPA": return "shippingbox.fill"
        case "Certificate": return "key.fill"
        case "Provisioning profile": return "doc.badge.gearshape"
        default: return "doc.fill"
        }
    }
}

private struct CatalogSource: Identifiable {
    let id: String
    let url: URL
    var name: String
    var apps: [CatalogApp]
    var status: String
}

private struct CatalogApp: Identifiable {
    let id: String
    let sourceID: String
    let name: String
    let developer: String
    let category: String
    let version: String
    let downloadURL: URL
}

@MainActor
private final class InstallerCatalog: ObservableObject {
    @Published private(set) var sources: [CatalogSource] = []
    @Published private(set) var apps: [CatalogApp] = []
    @Published private(set) var loadingSourceIDs: Set<String> = []
    @Published private(set) var downloadingIDs: Set<String> = []

    private let sourceKey = "workspace.installer.catalogSources"
    private let defaults: [URL] = [
        URL(string: "https://github.com/LiveContainer/LiveContainer/releases/download/1.0/apps.json")!,
        URL(string: "https://sidestore.io/apps-v2.json/")!,
        URL(string: "https://raw.githubusercontent.com/Nyasami/Ksign/main/repo.json")!
    ]

    func seedAndRefresh() async {
        if sources.isEmpty {
            let saved = UserDefaults.standard.stringArray(forKey: sourceKey) ?? []
            let urls = (saved.compactMap(URL.init(string:)) + defaults)
                .reduce(into: [String: URL]()) { result, url in result[url.absoluteString] = url }
                .values
            sources = urls.map { CatalogSource(id: $0.absoluteString, url: $0, name: $0.host ?? "Repository", apps: [], status: "Not refreshed") }
        }
        for source in sources {
            await refreshAsync(source)
        }
    }

    func addSource(_ rawValue: String) {
        guard let url = URL(string: rawValue.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
              url.host != nil, !sources.contains(where: { $0.url.absoluteString == url.absoluteString }) else { return }
        sources.append(CatalogSource(id: url.absoluteString, url: url, name: url.host ?? "Repository", apps: [], status: "Not refreshed"))
        persistSources()
        refresh(sources.last!)
    }

    func remove(at offsets: IndexSet) {
        sources.remove(atOffsets: offsets)
        rebuildApps()
        persistSources()
    }

    func refresh(_ source: CatalogSource) {
        Task { await refreshAsync(source) }
    }

    func download(_ app: CatalogApp, store: WorkspaceStore) {
        guard !downloadingIDs.contains(app.id) else { return }
        downloadingIDs.insert(app.id)
        Task {
            defer { downloadingIDs.remove(app.id) }
            do {
                let destination = try await fetchIPA(app, store: store)
                store.installerImportIPA(from: destination)
            } catch {
                store.importError = "Could not download \(app.name): \(error.localizedDescription)"
            }
        }
    }

    func fetchIPA(_ app: CatalogApp, store: WorkspaceStore) async throws -> URL {
        let (data, response) = try await URLSession.shared.data(from: app.downloadURL)
        guard (response as? HTTPURLResponse)?.statusCode ?? 0 >= 200,
              (response as? HTTPURLResponse)?.statusCode ?? 0 < 300,
              !data.isEmpty else { throw CatalogError.invalidDownload }
        let downloadsDirectory = store.workspaceFolderDirectory(named: "Downloads")
        try FileManager.default.createDirectory(at: downloadsDirectory, withIntermediateDirectories: true)
        let safeName = app.name.replacingOccurrences(of: "/", with: "-") + "-\(app.version).ipa"
        let destination = downloadsDirectory.appendingPathComponent(safeName, isDirectory: false)
        try data.write(to: destination, options: [.atomic])
        store.workspaceFilesDidChange()
        return destination
    }

    private func refreshAsync(_ source: CatalogSource) async {
        guard !loadingSourceIDs.contains(source.id) else { return }
        loadingSourceIDs.insert(source.id)
        defer { loadingSourceIDs.remove(source.id) }
        do {
            let (data, response) = try await URLSession.shared.data(from: source.url)
            guard (response as? HTTPURLResponse)?.statusCode ?? 0 >= 200,
                  (response as? HTTPURLResponse)?.statusCode ?? 0 < 300,
                  data.count <= 10_000_000 else { throw CatalogError.invalidResponse }
            let parsed = try parse(data: data, sourceURL: source.url)
            guard let index = sources.firstIndex(where: { $0.id == source.id }) else { return }
            sources[index].name = parsed.name
            sources[index].apps = parsed.apps
            sources[index].status = "Updated"
            rebuildApps()
        } catch {
            if let index = sources.firstIndex(where: { $0.id == source.id }) {
                sources[index].status = "Unavailable"
            }
        }
    }

    private func rebuildApps() {
        var seen = Set<String>()
        apps = sources.flatMap(\.apps).filter { seen.insert($0.id).inserted }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func persistSources() {
        UserDefaults.standard.set(sources.map { $0.url.absoluteString }, forKey: sourceKey)
    }

    private func parse(data: Data, sourceURL: URL) throws -> (name: String, apps: [CatalogApp]) {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawApps = root["apps"] as? [[String: Any]] else { throw CatalogError.invalidResponse }
        let sourceID = (root["identifier"] as? String) ?? (root["id"] as? String) ?? sourceURL.absoluteString
        let name = (root["name"] as? String) ?? sourceURL.host ?? "Repository"
        let apps = rawApps.compactMap { raw -> CatalogApp? in
            let bundleID = (raw["bundleIdentifier"] as? String) ?? (raw["id"] as? String)
            let appName = raw["name"] as? String
            guard let bundleID, let appName else { return nil }
            let developer = (raw["developerName"] as? String) ?? (raw["developer"] as? String) ?? "Unknown developer"
            let category = (raw["category"] as? String) ?? "Utilities"
            let versions = raw["versions"] as? [[String: Any]] ?? []
            let version = versions.first ?? raw
            guard let downloadString = (version["downloadURL"] as? String) ?? (raw["downloadURL"] as? String),
                  let parsedDownloadURL = URL(string: downloadString, relativeTo: sourceURL) else { return nil }
            let downloadURL = parsedDownloadURL.absoluteURL
            guard let scheme = downloadURL.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return nil }
            let versionName = (version["version"] as? String) ?? (raw["version"] as? String) ?? "Latest"
            return CatalogApp(id: "\(sourceID)|\(bundleID)|\(versionName)", sourceID: sourceID, name: appName, developer: developer, category: category, version: versionName, downloadURL: downloadURL)
        }
        return (name, apps)
    }
}

private enum CatalogError: LocalizedError {
    case invalidResponse
    case invalidDownload

    var errorDescription: String? {
        switch self {
        case .invalidResponse: return "The repository did not return a supported AltStore source."
        case .invalidDownload: return "The repository returned an invalid IPA download."
        }
    }
}

private struct InstallerStoreView: View {
    @ObservedObject var store: WorkspaceStore
    @StateObject private var catalog = InstallerCatalog()
    @State private var showingAddSource = false
    @State private var sourceURL = ""

    var body: some View {
        List {
            Section {
                ForEach(catalog.sources) { source in
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(source.name).font(.body.weight(.semibold))
                            Text("\(source.apps.count) apps · \(source.status)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button {
                            catalog.refresh(source)
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .disabled(catalog.loadingSourceIDs.contains(source.id))
                    }
                }
                .onDelete { offsets in catalog.remove(at: offsets) }
            } header: {
                HStack {
                    Text("Repositories")
                    Spacer()
                    Button {
                        showingAddSource = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("Add repository")
                }
            }

            Section("Apps") {
                if catalog.apps.isEmpty {
                    ContentUnavailableView("No catalog apps", systemImage: "shippingbox", description: Text("Refresh a repository or add an AltStore-compatible source."))
                } else {
                    ForEach(catalog.apps) { app in
                        HStack(spacing: 12) {
                            Image(systemName: "app.fill")
                                .foregroundStyle(.white)
                                .frame(width: 40, height: 40)
                                .background(.blue, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                            VStack(alignment: .leading, spacing: 3) {
                                Text(app.name).font(.body.weight(.semibold))
                                Text("\(app.developer) · \(app.category)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button(catalog.downloadingIDs.contains(app.id) ? "..." : "Get") {
                                catalog.download(app, store: store)
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                            .disabled(catalog.downloadingIDs.contains(app.id))
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .task {
            await catalog.seedAndRefresh()
        }
        .alert("Add repository", isPresented: $showingAddSource) {
            TextField("https://example.com/apps.json", text: $sourceURL)
                .textInputAutocapitalization(.never)
                .keyboardType(.URL)
            Button("Add") {
                catalog.addSource(sourceURL)
                sourceURL = ""
            }
            Button("Cancel", role: .cancel) { sourceURL = "" }
        } message: {
            Text("Use an AltStore, SideStore, eSign, or KSign-compatible JSON feed.")
        }
    }
}

private struct InstallerSource: Identifiable {
    let id: String
    let name: String
    let detail: String
    let symbol: String
    let tint: Color
    let status: String
    let repositoryURL: URL?

    static func custom(url: URL) -> InstallerSource {
        InstallerSource(
            id: "custom-\(url.absoluteString)",
            name: url.host ?? "Custom repository",
            detail: url.absoluteString,
            symbol: "link",
            tint: .blue,
            status: "Custom",
            repositoryURL: url
        )
    }

    static let catalog: [InstallerSource] = [
        InstallerSource(
            id: "workspace",
            name: "Workspace releases",
            detail: "Apps published by this workspace",
            symbol: "shippingbox.fill",
            tint: .orange,
            status: "Catalog",
            repositoryURL: URL(string: "https://github.com/Pkp107/HelloWorld-iOS27/releases")
        ),
        InstallerSource(
            id: "livecontainer",
            name: "LiveContainer",
            detail: "Native runtime and compatible releases",
            symbol: "bolt.horizontal.circle.fill",
            tint: .green,
            status: "Repository",
            repositoryURL: URL(string: "https://github.com/LiveContainer/LiveContainer")
        ),
        InstallerSource(
            id: "local",
            name: "Local files",
            detail: "Install an IPA from the Files app",
            symbol: "folder.fill",
            tint: .teal,
            status: "Ready",
            repositoryURL: nil
        )
    ]
}

struct AppLibraryView: View {
    @ObservedObject var store: WorkspaceStore
    let onOpen: (VirtualApp) -> Void
    @State private var showingImporter = false
    @State private var selectedSource: InstallerSource?
    @State private var selectedFolder: VirtualFolder?
    @State private var showingFolderPrompt = false
    @State private var newFolderName = ""
    @State private var showingAddSource = false
    @State private var sourceURLText = ""
    @State private var sourceError: String?
    @AppStorage("workspace.installer.repositories") private var savedRepositories = ""

    private var importedApps: [VirtualApp] {
        store.apps.filter { !$0.isBuiltIn }
    }

    private var sources: [InstallerSource] {
        let custom = savedRepositories
            .split(whereSeparator: { $0.isNewline })
            .compactMap { URL(string: String($0)) }
            .filter { $0.scheme?.lowercased() == "https" || $0.scheme?.lowercased() == "http" }
            .map(InstallerSource.custom(url:))
        return InstallerSource.catalog + custom
    }

    var body: some View {
#if LIVE_CONTAINER_NATIVE
        // LiveContainer's own app list owns the native IPA importer and
        // install pipeline. The fallback surface below provides the same
        // workflow as managed files for the lightweight target.
        NativeLiveContainerAppLibraryView()
            .navigationTitle("Installer")
#else
        NavigationStack {
            List {
                Section {
                    InstallerSummaryCard(
                        importedCount: importedApps.count,
                        runtime: LiveContainerRuntime.shared.availability
                    )
                    .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16))
                    .listRowBackground(Color.clear)
                }

                Section("Sources") {
                    ForEach(sources) { source in
                        Button {
                            if source.id == "local" {
                                showingImporter = true
                            } else {
                                selectedSource = source
                            }
                        } label: {
                            InstallerSourceRow(source: source)
                        }
                        .buttonStyle(.plain)
                    }
                }

                Section("Install") {
                    Button {
                        showingImporter = true
                    } label: {
                        Label("Import IPA from Files", systemImage: "tray.and.arrow.down.fill")
                    }

                    NavigationLink {
                        InstalledAppsView(store: store, onOpen: onOpen)
                    } label: {
                        Label("Installed apps", systemImage: "square.stack.3d.up.fill")
                    }

                }

                if !store.folders.isEmpty {
                    Section("Home screen folders") {
                        ForEach(store.folders) { folder in
                            Button {
                                selectedFolder = folder
                            } label: {
                                Label(folder.name, systemImage: folder.symbol)
                                    .foregroundStyle(.primary)
                            }
                        }
                        .onDelete { offsets in
                            for offset in offsets where offset < store.folders.count {
                                store.deleteFolder(store.folders[offset])
                            }
                        }
                    }
                }

                Section {
                    Button {
                        showingFolderPrompt = true
                    } label: {
                        Label("New folder", systemImage: "folder.badge.plus")
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Installer")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            showingImporter = true
                        } label: {
                            Label("Import IPA", systemImage: "tray.and.arrow.down")
                        }
                        Button {
                            sourceURLText = ""
                            sourceError = nil
                            showingAddSource = true
                        } label: {
                            Label("Add repository", systemImage: "link.badge.plus")
                        }
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("Installer actions")
                }
            }
        }
        .sheet(item: $selectedSource) { source in
            InstallerSourceDetailView(source: source, onImport: { showingImporter = true })
        }
        .sheet(item: $selectedFolder) { folder in
            FolderView(folder: folder, store: store, onOpen: onOpen)
        }
        .alert("New folder", isPresented: $showingFolderPrompt) {
            TextField("Folder name", text: $newFolderName)
            Button("Create") {
                store.createFolder(named: newFolderName)
                newFolderName = ""
            }
            Button("Cancel", role: .cancel) { newFolderName = "" }
        } message: {
            Text("Group apps on the Home screen.")
        }
        .alert("Add repository", isPresented: $showingAddSource) {
            TextField("https://example.com/apps.json", text: $sourceURLText)
                .textInputAutocapitalization(.never)
                .keyboardType(.URL)
            Button("Add") {
                addRepository()
            }
            Button("Cancel", role: .cancel) { sourceURLText = "" }
        } message: {
            Text(sourceError ?? "Add an AltStore, SideStore, eSign, or KSign-compatible JSON feed.")
        }
        .fileImporter(
            isPresented: $showingImporter,
            allowedContentTypes: [.ipa, .zip, .data],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first { store.importIPA(from: url) }
            case .failure(let error):
                store.importError = error.localizedDescription
            }
        }
        .alert("Import problem", isPresented: Binding(
            get: { store.importError != nil },
            set: { if !$0 { store.importError = nil } }
        )) {
            Button("OK", role: .cancel) { store.importError = nil }
        } message: {
            Text(store.importError ?? "")
        }
#endif
    }

    private func addRepository() {
        let value = sourceURLText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: value),
              let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              url.host != nil else {
            sourceError = "Enter a valid HTTP or HTTPS repository URL."
            showingAddSource = true
            return
        }
        var values = savedRepositories.split(whereSeparator: { $0.isNewline }).map(String.init)
        if !values.contains(url.absoluteString) {
            values.append(url.absoluteString)
            savedRepositories = values.joined(separator: "\n")
        }
        sourceURLText = ""
        sourceError = nil
    }
}

private struct InstallerSummaryCard: View {
    let importedCount: Int
    let runtime: RuntimeAvailability

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: "arrow.down.app.fill")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(.orange, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    Text("Install apps")
                        .font(.headline)
                    Text("Import an IPA or browse a release source.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 16) {
                Label("\(importedCount) installed", systemImage: "square.stack.3d.up")
                Label(runtime == .nativeFrameworkDetected ? "Runtime ready" : "Managed mode", systemImage: runtime == .nativeFrameworkDetected ? "checkmark.circle.fill" : "info.circle")
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Installer. \(importedCount) installed apps. \(runtime.label).")
    }
}

private struct InstallerSourceRow: View {
    let source: InstallerSource

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: source.symbol)
                .font(.headline)
                .foregroundStyle(.white)
                .frame(width: 38, height: 38)
                .background(source.tint, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(source.name)
                    .font(.body.weight(.semibold))
                Text(source.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(source.status)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Image(systemName: source.id == "local" ? "tray.and.arrow.down" : "chevron.right")
                .font(.caption.weight(.bold))
                .foregroundStyle(.tertiary)
        }
        .frame(minHeight: 44)
    }
}

private struct InstallerSourceDetailView: View {
    let source: InstallerSource
    let onImport: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 14) {
                        Image(systemName: source.symbol)
                            .font(.title2.weight(.semibold))
                            .foregroundStyle(.white)
                            .frame(width: 52, height: 52)
                            .background(source.tint, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        VStack(alignment: .leading, spacing: 4) {
                            Text(source.name)
                                .font(.headline)
                            Text(source.detail)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 8)
                }

                Section("Source") {
                    LabeledContent("Status", value: source.status)
                    if let repositoryURL = source.repositoryURL {
                        Link(destination: repositoryURL) {
                            Label("Open repository", systemImage: "arrow.up.right.square")
                        }
                    }
                }

                Section {
                    Button {
                        onImport()
                        dismiss()
                    } label: {
                        Label("Import an IPA", systemImage: "tray.and.arrow.down.fill")
                    }
                } footer: {
                    Text("Repository browsing is informational in this build. Download an IPA in Safari or Files, then import it here.")
                }
            }
            .navigationTitle("Source details")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

struct InstalledAppsView: View {
    @ObservedObject var store: WorkspaceStore
    let onOpen: (VirtualApp) -> Void
    @State private var searchText = ""
    @State private var editingApp: VirtualApp?
    @State private var showingImporter = false

    private var importedApps: [VirtualApp] {
        let apps = store.apps.filter { !$0.isBuiltIn }
        guard !searchText.isEmpty else { return apps }
        return apps.filter { app in
            app.displayName.localizedCaseInsensitiveContains(searchText) ||
            app.category.localizedCaseInsensitiveContains(searchText) ||
            app.bundleIdentifier.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
#if LIVE_CONTAINER_NATIVE
        NativeLiveContainerAppLibraryView()
            .navigationTitle("Installed Apps")
#else
        NavigationStack {
            List {
                Section {
                    if importedApps.isEmpty {
                        if searchText.isEmpty {
                            ContentUnavailableView(
                                "No installed apps",
                                systemImage: "square.stack.3d.up",
                                description: Text("Import an IPA from Installer to add it here.")
                            )
                        } else {
                            ContentUnavailableView(
                                "No matching apps",
                                systemImage: "magnifyingglass",
                                description: Text("Try a different search.")
                            )
                        }
                    } else {
                        ForEach(importedApps) { app in
                            AppLibraryRow(app: app, store: store, onOpen: onOpen, onEdit: { editingApp = app })
                        }
                        .onDelete { offsets in
                            for offset in offsets where offset < importedApps.count {
                                store.remove(importedApps[offset])
                            }
                        }
                    }
                } header: {
                    Text("LiveContainer")
                } footer: {
                    Text("Imported IPAs stay in app-owned storage. Guest execution depends on the native LiveContainer runtime and a compatible signing path.")
                }
            }
            .listStyle(.insetGrouped)
            .searchable(text: $searchText, prompt: "Search installed apps")
            .navigationTitle("Installed Apps")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showingImporter = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("Import IPA")
                }
            }
        }
        .sheet(item: $editingApp) { app in
            AppDetailsView(app: app, store: store)
        }
        .fileImporter(
            isPresented: $showingImporter,
            allowedContentTypes: [.ipa, .zip, .data],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first { store.importIPA(from: url) }
            case .failure(let error):
                store.importError = error.localizedDescription
            }
        }
#endif
    }
}

/// The installed-apps launcher entry is deliberately separate from Installer:
/// one owns package discovery/import, the other owns the guest runtime list.
struct LiveContainerAppsView: View {
    @ObservedObject var store: WorkspaceStore
    let onOpen: (VirtualApp) -> Void

    var body: some View {
        InstalledAppsView(store: store, onOpen: onOpen)
    }
}

private struct AppLibraryRow: View {
    let app: VirtualApp
    @ObservedObject var store: WorkspaceStore
    let onOpen: (VirtualApp) -> Void
    let onEdit: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: app.iconSymbol)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 42, height: 42)
                .background(Color.workspaceAccent(app.iconColor), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(app.displayName)
                    .font(.body.weight(.semibold))
                Text("\(app.category) · \(app.status.label)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button { onOpen(app) } label: {
                Image(systemName: "arrow.up.right.square")
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open \(app.displayName)")
            Menu {
                Button("Edit metadata", action: onEdit)
                Menu("Move to folder") {
                    Button("Home screen") { store.move(app, to: nil) }
                    ForEach(store.folders) { folder in
                        Button(folder.name) { store.move(app, to: folder) }
                    }
                }
                if !app.isBuiltIn {
                    Button("Remove app", role: .destructive) { store.remove(app) }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("Actions for \(app.displayName)")
        }
    }
}

struct AppDetailsView: View {
    let app: VirtualApp
    @ObservedObject var store: WorkspaceStore
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var category: String
    @State private var icon: String
    @State private var color: String
    @State private var pinned: Bool

    init(app: VirtualApp, store: WorkspaceStore) {
        self.app = app
        self.store = store
        _name = State(initialValue: app.displayName)
        _category = State(initialValue: app.category)
        _icon = State(initialValue: app.iconSymbol)
        _color = State(initialValue: app.iconColor)
        _pinned = State(initialValue: app.isPinned)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Identity") {
                    TextField("Name", text: $name)
                    TextField("Category", text: $category)
                    TextField("SF Symbol", text: $icon)
                    Picker("Accent", selection: $color) {
                        ForEach(["blue", "teal", "green", "orange", "purple", "pink", "red", "indigo", "gray"], id: \.self) { value in
                            Text(value.capitalized).tag(value)
                        }
                    }
                    Toggle("Show in dock", isOn: $pinned)
                }
                Section("Package") {
                    LabeledContent("Bundle ID", value: app.bundleIdentifier)
                    LabeledContent("Version", value: app.version)
                    LabeledContent("Status", value: app.status.label)
                    if let fileName = app.ipaFileName {
                        LabeledContent("IPA file", value: fileName)
                    }
                }
            }
            .navigationTitle("App metadata")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        var updated = app
                        updated.displayName = name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? app.displayName : name
                        updated.category = category
                        updated.iconSymbol = icon.isEmpty ? "square.dashed" : icon
                        updated.iconColor = color
                        updated.isPinned = pinned
                        store.update(updated)
                        dismiss()
                    }
                }
            }
        }
    }
}

struct FolderView: View {
    let folder: VirtualFolder
    @ObservedObject var store: WorkspaceStore
    let onOpen: (VirtualApp) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                ForEach(store.apps(in: folder)) { app in
                    Button { onOpen(app) } label: {
                        Label(app.displayName, systemImage: app.iconSymbol)
                    }
                    .foregroundStyle(.primary)
                }
                if store.apps(in: folder).isEmpty {
                    ContentUnavailableView("Empty folder", systemImage: "folder", description: Text("Move apps here from App Library."))
                }
            }
            .navigationTitle(folder.name)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

struct SettingsView: View {
    @ObservedObject var store: WorkspaceStore
    @State private var searchText = ""

    private func matches(_ terms: String...) -> Bool {
        guard !searchText.isEmpty else { return true }
        return terms.contains { $0.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if matches("Customization", "Appearance", "Wallpaper", "background", "glass") {
                        NavigationLink {
                            CustomizationSettingsView(store: store)
                        } label: {
                            Label("Customization", systemImage: "paintbrush.fill")
                        }
                    }
                    if matches("Home screen", "grid", "labels", "motion", "remove") {
                        NavigationLink {
                            HomeScreenSettingsView(store: store)
                        } label: {
                            Label("Home Screen", systemImage: "square.grid.3x3.fill")
                        }
                    }
                    if matches("Signing", "certificate", "profile", "p12", "mobileprovision", "JIT") {
                        NavigationLink {
                            SigningAndJITSettingsView(store: store)
                        } label: {
                            Label("Signing and JIT", systemImage: "key.viewfinder")
                        }
                    }
                    if matches("LiveContainer", "runtime", "guest", "JIT") {
                        NavigationLink {
                            LiveContainerSettingsView(store: store)
                        } label: {
                            Label("LiveContainer", systemImage: "bolt.horizontal.circle.fill")
                        }
                    }
                } header: {
                    Text("Workspace")
                }

                Section {
                    if matches("Reset", "workspace", "advanced") {
                        Button("Reset workspace", role: .destructive) {
                            store.resetWorkspace()
                        }
                    }
                } header: {
                    Text("Advanced")
                }

                if !matches("Customization", "Appearance", "Wallpaper", "background", "glass", "Home screen", "grid", "labels", "motion", "remove", "Signing", "certificate", "profile", "p12", "mobileprovision", "JIT", "LiveContainer", "runtime", "guest", "Reset", "workspace", "advanced") {
                    ContentUnavailableView("No matching settings", systemImage: "magnifyingglass", description: Text("Try a different search."))
                }
            }
            .searchable(text: $searchText, prompt: "Search settings")
            .navigationTitle("Settings")
            .onChange(of: store.settings) { _, _ in
                store.settingsDidChange()
            }
        }
    }
}

struct CustomizationSettingsView: View {
    @ObservedObject var store: WorkspaceStore
    @State private var showingWallpaperImporter = false

    var body: some View {
        Form {
            Section("Background") {
                Picker("Wallpaper", selection: Binding(
                    get: { store.settings.wallpaper.rawValue },
                    set: { store.settings.wallpaper = WallpaperOption(rawValue: $0) ?? store.settings.wallpaper }
                )) {
                    ForEach(WallpaperOption.allCases) { option in
                        Label(option.label, systemImage: option.iconSymbol).tag(option.rawValue)
                    }
                }
                Button {
                    showingWallpaperImporter = true
                } label: {
                    Label(store.settings.wallpaper == .custom ? "Replace background photo" : "Choose background photo", systemImage: "photo.on.rectangle")
                }
                if store.settings.wallpaper == .custom {
                    Button("Remove custom background", role: .destructive) { store.removeCustomWallpaper() }
                }
            }
            Section("Material") {
                Picker("Glass style", selection: Binding(
                    get: { store.settings.glassStyle.rawValue },
                    set: { store.settings.glassStyle = GlassStyle(rawValue: $0) ?? store.settings.glassStyle }
                )) {
                    ForEach(GlassStyle.allCases) { style in Text(style.label).tag(style.rawValue) }
                }
                Slider(value: $store.settings.glassOpacity, in: 0.35...1) {
                    Text("Glass opacity")
                } minimumValueLabel: { Image(systemName: "circle.lefthalf.filled") } maximumValueLabel: { Image(systemName: "circle.fill") }
            }
        }
        .navigationTitle("Customization")
        .fileImporter(isPresented: $showingWallpaperImporter, allowedContentTypes: [.image], allowsMultipleSelection: false) { result in
            if case .success(let urls) = result, let url = urls.first { _ = store.importWallpaper(from: url) }
        }
    }
}

struct HomeScreenSettingsView: View {
    @ObservedObject var store: WorkspaceStore

    var body: some View {
        Form {
            Section("Layout") {
                Toggle("Show app labels", isOn: $store.settings.showAppLabels)
                Stepper("Home columns: \(store.settings.gridColumns)", value: $store.settings.gridColumns, in: 2...5)
                Toggle("Reduce motion", isOn: $store.settings.reduceShellMotion)
            }
            Section("App removal") {
                Toggle("Confirm app removal", isOn: $store.settings.confirmRemoval)
                Text("Use an app icon context menu to remove a LiveContainer guest from the home screen.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Home Screen")
    }
}

struct SigningAndJITSettingsView: View {
    @ObservedObject var store: WorkspaceStore
    @StateObject private var assetStore = SigningAssetStore()
    @State private var showingCertificateImporter = false
    @State private var showingProfileImporter = false
    @State private var certificatePassword = ""
    @State private var statusMessage: String?

    var body: some View {
        Form {
            Section("Signing assets") {
                signingAssetRow(
                    kind: .certificate,
                    asset: assetStore.asset(for: .certificate),
                    importer: $showingCertificateImporter,
                    placeholder: "Choose .p12 or .pfx"
                )
                signingAssetRow(
                    kind: .provisioningProfile,
                    asset: assetStore.asset(for: .provisioningProfile),
                    importer: $showingProfileImporter,
                    placeholder: "Choose .mobileprovision"
                )
                Text("These files are shared with Installer. They stay in protected Workspace storage.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Text("You can also use Files > Share > Workspace for both signing files.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Certificate JIT") {
                Picker("JIT provider", selection: Binding(
                    get: { store.settings.jitProvider.rawValue },
                    set: { store.settings.jitProvider = JITProvider(rawValue: $0) ?? store.settings.jitProvider }
                )) {
                    ForEach(JITProvider.allCases) { provider in
                        Text(provider.label).tag(provider.rawValue)
                    }
                }
                Toggle("Enable JIT", isOn: $store.settings.jitEnabled)
                if store.settings.jitProvider == .certificate {
                    SecureField("Certificate password", text: $certificatePassword)
                        .textContentType(.password)
                        .onChange(of: certificatePassword) { _, value in
                            WorkspaceCertificatePasswordStore.save(value)
                        }
#if LIVE_CONTAINER_NATIVE
                    Button("Configure LiveContainer JIT") {
                        configureLiveContainerJIT()
                    }
                    .disabled(assetStore.asset(for: .certificate) == nil || certificatePassword.isEmpty)
#else
                    Text("Certificate JIT is available in the integrated Workspace build.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
#endif
                }
                if let statusMessage {
                    Text(statusMessage)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else if let errorMessage = assetStore.errorMessage {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }
        }
        .navigationTitle("Certificates and JIT")
        .onAppear {
            if certificatePassword.isEmpty {
                certificatePassword = WorkspaceCertificatePasswordStore.load()
            }
        }
        .onChange(of: store.settings) { _, _ in store.settingsDidChange() }
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

    private func configureLiveContainerJIT() {
#if LIVE_CONTAINER_NATIVE
        do {
            try NativeSigningConfiguration.configureLiveContainerJIT(
                with: assetStore,
                certificatePassword: certificatePassword
            )
            statusMessage = "Certificate configured for LiveContainer JIT."
        } catch {
            statusMessage = error.localizedDescription
        }
#endif
    }
}

struct LiveContainerSettingsView: View {
    @ObservedObject var store: WorkspaceStore

    var body: some View {
#if LIVE_CONTAINER_NATIVE
        NativeLiveContainerSettingsView()
#else
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Runtime", value: LiveContainerRuntime.shared.availability.label)
                    LabeledContent("Stored apps", value: "\(store.apps.filter { !$0.isBuiltIn }.count)")
                    Text("Imported IPAs remain in app-owned storage until the native LiveContainer bootstrap and signing path are available in this build.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("Status")
                }

                Section("Execution") {
                    Picker("Launch mode", selection: Binding(
                        get: { store.settings.launchMode.rawValue },
                        set: { store.settings.launchMode = LaunchMode(rawValue: $0) ?? store.settings.launchMode }
                    )) {
                        ForEach(LaunchMode.allCases) { mode in
                            Text(mode.label).tag(mode.rawValue)
                        }
                    }
                    Toggle("Enable JIT", isOn: $store.settings.jitEnabled)
                    Picker("JIT provider", selection: Binding(
                        get: { store.settings.jitProvider.rawValue },
                        set: { store.settings.jitProvider = JITProvider(rawValue: $0) ?? store.settings.jitProvider }
                    )) {
                        ForEach(JITProvider.allCases) { provider in
                            Text(provider.label).tag(provider.rawValue)
                        }
                    }
                    if store.settings.jitEnabled {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("JIT app list")
                                .font(.subheadline.weight(.semibold))
                            if store.installedApps.isEmpty {
                                Text("Import an app to choose which guests receive JIT.")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            } else {
                                ForEach(store.installedApps) { app in
                                    Toggle(
                                        app.displayName,
                                        isOn: Binding(
                                            get: { store.settings.jitAppIDs.contains(app.id) },
                                            set: { enabled in
                                                if enabled {
                                                    store.settings.jitAppIDs.insert(app.id)
                                                } else {
                                                    store.settings.jitAppIDs.remove(app.id)
                                                }
                                                store.settingsDidChange()
                                            }
                                        )
                                    )
                                }
                            }
                        }
                    }
                }

                Section("Background") {
                    Toggle("Allow background execution", isOn: $store.settings.backgroundExecutionEnabled)
                    Stepper("App limit: \(store.settings.backgroundAppLimit)", value: $store.settings.backgroundAppLimit, in: 1...8)
                }

                Section("Audio") {
                    Toggle("Per-app audio", isOn: $store.settings.perAppAudioEnabled)
                    Toggle("Show recent apps in dock", isOn: $store.settings.showDockRecents)
                    if store.settings.perAppAudioEnabled {
                        ForEach(store.installedApps) { app in
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Label(app.displayName, systemImage: app.iconSymbol)
                                        .lineLimit(1)
                                    Spacer()
                                    Toggle(
                                        "Mute",
                                        isOn: Binding(
                                            get: { store.settings.mutedAppIDs.contains(app.id) },
                                            set: { store.setMuted($0, for: app) }
                                        )
                                    )
                                    .labelsHidden()
                                }
                                Slider(
                                    value: Binding(
                                        get: { store.audioLevel(for: app) },
                                        set: { store.setAudioLevel($0, for: app) }
                                    ),
                                    in: 0...1
                                ) {
                                    Text("Volume")
                                }
                                .accessibilityLabel("Volume for \(app.displayName)")
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }
            }
            .navigationTitle("LiveContainer")
            .onChange(of: store.settings) { _, _ in
                store.settingsDidChange()
            }
        }
#endif
    }
}

#if LIVE_CONTAINER_NATIVE
@MainActor
struct IPASignerView: View {
    @ObservedObject var store: WorkspaceStore

    var body: some View {
        NativeIPASignerView()
    }
}
#else
@MainActor
struct IPASignerView: View {
    @ObservedObject var store: WorkspaceStore
    @StateObject private var assetStore = SigningAssetStore()
    @StateObject private var packageStore = SigningPackageStore()
    @State private var showingPackageImporter = false
    @State private var showingCertificateImporter = false
    @State private var showingProfileImporter = false
    @State private var certificatePassword = ""
    @State private var statusMessage: String?

    private var certificateAsset: SigningAsset? {
        assetStore.asset(for: .certificate)
    }

    private var profileAsset: SigningAsset? {
        assetStore.asset(for: .provisioningProfile)
    }

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
                        }
                    }
                    Text("This IPA is kept only for signing. It is not added to Workspace or LiveContainer.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("Signing assets") {
                    signingAssetRow(
                        kind: .certificate,
                        asset: certificateAsset,
                        importer: $showingCertificateImporter,
                        placeholder: "Choose .p12"
                    )
                    signingAssetRow(
                        kind: .provisioningProfile,
                        asset: profileAsset,
                        importer: $showingProfileImporter,
                        placeholder: "Choose .mobileprovision"
                    )
                    SecureField("Certificate password", text: $certificatePassword)
                        .textContentType(.password)
                        .onChange(of: certificatePassword) { _, value in
                            WorkspaceCertificatePasswordStore.save(value)
                        }
                    Text("Signing requires a certificate and profile that match the target device. The password is stored locally for future signing and JIT setup.")
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
                    Button("Prepare signing package") {
                        statusMessage = "The IPA, certificate, and provisioning profile are ready. The integrated Workspace build can export the signed IPA."
                    }
                    .frame(minHeight: 44)
                    .disabled(packageStore.package == nil || certificateAsset == nil || profileAsset == nil || certificatePassword.isEmpty)
                } footer: {
                    Text("The lightweight target validates and stores the signing package. Use the integrated Workspace artifact to sign and export it.")
                }
            }
            .navigationTitle("Signing")
        }
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
        .fileImporter(isPresented: $showingCertificateImporter, allowedContentTypes: SigningAssetKind.certificate.fileImporterContentTypes, allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first { _ = assetStore.importAsset(from: url, kind: .certificate) }
            case .failure(let error):
                assetStore.errorMessage = error.localizedDescription
            }
        }
        .fileImporter(isPresented: $showingProfileImporter, allowedContentTypes: SigningAssetKind.provisioningProfile.fileImporterContentTypes, allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first { _ = assetStore.importAsset(from: url, kind: .provisioningProfile) }
            case .failure(let error):
                assetStore.errorMessage = error.localizedDescription
            }
        }
        .alert("Signing", isPresented: Binding(
            get: { statusMessage != nil },
            set: { if !$0 { statusMessage = nil } }
        )) {
            Button("OK", role: .cancel) { statusMessage = nil }
        } message: {
            Text(statusMessage ?? "")
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
            Button {
                importer.wrappedValue = true
            } label: {
                LabeledContent(kind.label, value: asset?.originalName ?? placeholder)
            }
            .buttonStyle(.plain)

            if let asset {
                Button(role: .destructive) {
                    assetStore.remove(asset)
                } label: {
                    Image(systemName: "trash")
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Remove \(kind.label)")
            }
        }
    }
}
#endif
