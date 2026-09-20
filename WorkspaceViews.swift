import SwiftUI

struct AppLibraryView: View {
    @ObservedObject var store: WorkspaceStore
    let onOpen: (VirtualApp) -> Void
    @State private var searchText = ""
    @State private var showingFolderPrompt = false
    @State private var newFolderName = ""
    @State private var editingApp: VirtualApp?
    @State private var showingImporter = false

    private var filteredApps: [VirtualApp] {
        guard !searchText.isEmpty else { return store.apps }
        return store.apps.filter { app in
            app.displayName.localizedCaseInsensitiveContains(searchText) ||
            app.category.localizedCaseInsensitiveContains(searchText) ||
            app.bundleIdentifier.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Section("Apps") {
                    ForEach(filteredApps) { app in
                        AppLibraryRow(app: app, store: store, onOpen: onOpen, onEdit: { editingApp = app })
                    }
                    .onDelete { offsets in
                        for offset in offsets where offset < filteredApps.count {
                            let app = filteredApps[offset]
                            if !app.isBuiltIn { store.remove(app) }
                        }
                    }
                }

                Section("Folders") {
                    ForEach(store.folders) { folder in
                        Label(folder.name, systemImage: folder.symbol)
                    }
                    .onDelete { offsets in
                        for offset in offsets where offset < store.folders.count {
                            store.deleteFolder(store.folders[offset])
                        }
                    }
                    Button {
                        showingFolderPrompt = true
                    } label: {
                        Label("New folder", systemImage: "folder.badge.plus")
                    }
                }
            }
            .searchable(text: $searchText, prompt: "Search apps")
            .navigationTitle("App Library")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showingImporter = true
                    } label: {
                        Image(systemName: "tray.and.arrow.down")
                    }
                    .accessibilityLabel("Import IPA")
                }
            }
        }
        .sheet(item: $editingApp) { app in
            AppDetailsView(app: app, store: store)
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

    var body: some View {
        NavigationStack {
            Form {
                Section("Home") {
                    Toggle("Show app labels", isOn: $store.settings.showAppLabels)
                    Stepper("Home columns: \(store.settings.gridColumns)", value: $store.settings.gridColumns, in: 2...5)
                    Toggle("Confirm app removal", isOn: $store.settings.confirmRemoval)
                    Toggle("Reduce motion", isOn: $store.settings.reduceShellMotion)
                }
                Section("LiveContainer") {
                    Label(LiveContainerRuntime.shared.availability.label, systemImage: "bolt.horizontal.circle")
                    Text("The workspace keeps imported IPAs in app-owned storage. Full guest execution requires the upstream native bootstrap, loader, extensions, entitlements, and signing or JIT path.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Section {
                    Button("Reset workspace", role: .destructive) {
                        store.resetWorkspace()
                    }
                }
            }
            .navigationTitle("Settings")
            .onChange(of: store.settings) { _, _ in
                store.settingsDidChange()
            }
        }
    }
}

struct IPASignerView: View {
    @ObservedObject var store: WorkspaceStore
    @State private var selectedAppID: UUID?
    @State private var certificateName = ""
    @State private var profileName = ""
    @State private var showingCertificateImporter = false
    @State private var showingProfileImporter = false

    private var importedApps: [VirtualApp] {
        store.apps.filter { !$0.isBuiltIn }
    }

    private var selectedApp: VirtualApp? {
        importedApps.first(where: { $0.id == selectedAppID })
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if importedApps.isEmpty {
                        ContentUnavailableView("No IPA files", systemImage: "shippingbox", description: Text("Import an IPA from App Library first."))
                    } else {
                        Picker("IPA", selection: $selectedAppID) {
                            Text("Choose an app").tag(UUID?.none)
                            ForEach(importedApps) { app in
                                Text(app.displayName).tag(Optional(app.id))
                            }
                        }
                    }
                } header: {
                    Text("Package")
                }

                Section("Signing assets") {
                    Button {
                        showingCertificateImporter = true
                    } label: {
                        LabeledContent("Certificate", value: certificateName.isEmpty ? "Choose .p12" : certificateName)
                    }
                    Button {
                        showingProfileImporter = true
                    } label: {
                        LabeledContent("Provisioning profile", value: profileName.isEmpty ? "Choose .mobileprovision" : profileName)
                    }
                    Text("Signing requires a certificate and profile that match the target device. Assets stay inside this app's sandbox.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section {
                    Button("Prepare signed IPA") {
                        if let selectedApp {
                            store.prepareSigning(for: selectedApp, certificateName: certificateName, profileName: profileName)
                        }
                    }
                    .frame(minHeight: 44)
                    .disabled(selectedApp == nil || certificateName.isEmpty || profileName.isEmpty)
                } footer: {
                    Text("The current build exposes the signing workflow and validation surface. A native ZSign backend must be linked before it can export a signed IPA.")
                }
            }
            .navigationTitle("IPA Signer")
        }
        .onAppear {
            if selectedAppID == nil { selectedAppID = importedApps.first?.id }
        }
        .fileImporter(isPresented: $showingCertificateImporter, allowedContentTypes: [.data], allowsMultipleSelection: false) { result in
            if case .success(let urls) = result { certificateName = urls.first?.lastPathComponent ?? "" }
        }
        .fileImporter(isPresented: $showingProfileImporter, allowedContentTypes: [.data], allowsMultipleSelection: false) { result in
            if case .success(let urls) = result { profileName = urls.first?.lastPathComponent ?? "" }
        }
        .alert("Signing", isPresented: Binding(
            get: { store.signingMessage != nil },
            set: { if !$0 { store.signingMessage = nil } }
        )) {
            Button("OK", role: .cancel) { store.signingMessage = nil }
        } message: {
            Text(store.signingMessage ?? "")
        }
    }
}
