import Foundation
import SwiftUI
import UniformTypeIdentifiers

/// Compatibility wrapper for the launcher entry named Installer. The native
/// build swaps the underlying surface for LiveContainer's real importer.
struct InstallerView: View {
    @ObservedObject var store: WorkspaceStore
    let onOpen: (VirtualApp) -> Void

    var body: some View {
        AppLibraryView(store: store, onOpen: onOpen)
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

                    NavigationLink {
                        IPASignerView(store: store)
                    } label: {
                        Label("IPA Signer", systemImage: "signature")
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
    @State private var showingWallpaperImporter = false

    private func matches(_ terms: String...) -> Bool {
        guard !searchText.isEmpty else { return true }
        return terms.contains { $0.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        NavigationStack {
            Form {
                if matches("Home", "grid", "labels", "motion") {
                    Section("Home screen") {
                        Toggle("Show app labels", isOn: $store.settings.showAppLabels)
                        Stepper("Home columns: \(store.settings.gridColumns)", value: $store.settings.gridColumns, in: 2...5)
                        Toggle("Confirm app removal", isOn: $store.settings.confirmRemoval)
                        Toggle("Reduce motion", isOn: $store.settings.reduceShellMotion)
                    }
                }

                if matches("Appearance", "wallpaper", "glass", "opacity") {
                    Section("Appearance") {
                        Picker("Wallpaper", selection: Binding(
                            get: { store.settings.wallpaper.rawValue },
                            set: { store.settings.wallpaper = WallpaperOption(rawValue: $0) ?? store.settings.wallpaper }
                        )) {
                            ForEach(WallpaperOption.allCases) { option in
                                Label(option.label, systemImage: option.iconSymbol)
                                    .tag(option.rawValue)
                            }
                        }
                        Picker("Glass style", selection: Binding(
                            get: { store.settings.glassStyle.rawValue },
                            set: { store.settings.glassStyle = GlassStyle(rawValue: $0) ?? store.settings.glassStyle }
                        )) {
                            ForEach(GlassStyle.allCases) { style in
                                Text(style.label).tag(style.rawValue)
                            }
                        }
                        Button {
                            showingWallpaperImporter = true
                        } label: {
                            Label(
                                store.settings.wallpaper == .custom ? "Replace wallpaper photo" : "Choose wallpaper photo",
                                systemImage: "photo.on.rectangle"
                            )
                        }
                        if store.settings.wallpaper == .custom {
                            Button("Remove custom wallpaper", role: .destructive) {
                                store.removeCustomWallpaper()
                            }
                        }
                        Slider(value: $store.settings.glassOpacity, in: 0.35...1) {
                            Text("Glass opacity")
                        } minimumValueLabel: {
                            Image(systemName: "circle.lefthalf.filled")
                        } maximumValueLabel: {
                            Image(systemName: "circle.fill")
                        }
                        .accessibilityValue("\(Int(store.settings.glassOpacity * 100)) percent")
                    }
                }

                if matches("Signing", "certificate", "profile", "p12", "mobileprovision", "JIT") {
                    Section("Signing and JIT") {
                        NavigationLink {
                            SigningAndJITSettingsView(store: store)
                        } label: {
                            Label("Certificates and JIT", systemImage: "key.viewfinder")
                        }
                    }
                }

                if matches("LiveContainer", "runtime", "JIT", "installed apps") {
                    Section("Runtime") {
                        NavigationLink {
                            LiveContainerSettingsView(store: store)
                        } label: {
                            Label {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("LiveContainer")
                                        .font(.body.weight(.semibold))
                                    Text(LiveContainerRuntime.shared.availability.label)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            } icon: {
                                Image(systemName: "bolt.horizontal.circle.fill")
                                    .foregroundStyle(.green)
                            }
                        }
                    }
                }

                if matches("Reset", "workspace", "advanced") {
                    Section("Advanced") {
                        Button("Reset workspace", role: .destructive) {
                            store.resetWorkspace()
                        }
                    }
                }

                if !matches("Home", "grid", "labels", "motion", "Appearance", "wallpaper", "glass", "opacity", "Signing", "certificate", "profile", "p12", "mobileprovision", "JIT", "LiveContainer", "runtime", "installed apps", "Reset", "workspace", "advanced") {
                    ContentUnavailableView("No matching settings", systemImage: "magnifyingglass", description: Text("Try a different search.") )
                }
            }
            .searchable(text: $searchText, prompt: "Search settings")
            .navigationTitle("Settings")
            .onChange(of: store.settings) { _, _ in
                store.settingsDidChange()
            }
            .fileImporter(
                isPresented: $showingWallpaperImporter,
                allowedContentTypes: [.image],
                allowsMultipleSelection: false
            ) { result in
                if case .success(let urls) = result, let url = urls.first {
                    _ = store.importWallpaper(from: url)
                }
            }
        }
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
                Text("These files are shared with IPA Signer. They stay in protected Workspace storage.")
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
            .navigationTitle("IPA Signer")
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
        .alert("IPA Signer", isPresented: Binding(
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
