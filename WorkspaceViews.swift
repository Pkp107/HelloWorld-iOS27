import SwiftUI

struct AppLibraryView: View {
    @ObservedObject var store: WorkspaceStore
    let onOpen: (VirtualApp) -> Void
    let onImport: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""
    @State private var showingFolderPrompt = false
    @State private var newFolderName = ""
    @State private var editingApp: VirtualApp?

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
            .navigationTitle("App library")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        dismiss()
                        DispatchQueue.main.async(execute: onImport)
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
            Text("Group apps on your HelloOS home screen.")
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
                        ForEach(["blue", "teal", "green", "orange", "purple", "pink", "red", "indigo"], id: \.self) { value in
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
                    ContentUnavailableView("Empty folder", systemImage: "folder", description: Text("Move apps here from the library."))
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

struct TaskSwitcherView: View {
    @ObservedObject var store: WorkspaceStore
    let onOpen: (VirtualApp) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if store.sessions.isEmpty {
                    ContentUnavailableView("No open apps", systemImage: "rectangle.stack", description: Text("Open an app from the HelloOS workspace to see it here."))
                } else {
                    ScrollView(.horizontal) {
                        LazyHStack(spacing: 16) {
                            ForEach(store.sessions) { session in
                                if let app = store.app(for: session.appID) {
                                    TaskCard(app: app, session: session, onOpen: { onOpen(app) }, onClose: { store.close(app) })
                                }
                            }
                        }
                        .padding(.horizontal, 20)
                    }
                }
            }
            .navigationTitle("Task switcher")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

private struct TaskCard: View {
    let app: VirtualApp
    let session: RuntimeSession
    let onOpen: () -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image(systemName: app.iconSymbol)
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(Color.workspaceAccent(app.iconColor))
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close \(app.displayName)")
            }
            Spacer(minLength: 0)
            Text(app.displayName)
                .font(.title3.weight(.bold))
            Label(session.state == .running ? "Open" : "Suspended", systemImage: session.state == .running ? "circle.fill" : "pause.circle")
                .font(.subheadline)
                .foregroundStyle(session.state == .running ? Color.green : Color.secondary)
            Button("Resume", action: onOpen)
                .buttonStyle(.borderedProminent)
                .frame(minHeight: 44)
        }
        .padding(18)
        .frame(width: 250, height: 230)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(.separator))
    }
}

struct SettingsView: View {
    @ObservedObject var store: WorkspaceStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Workspace") {
                    Toggle("Show app labels", isOn: $store.settings.showAppLabels)
                    Stepper("Home columns: \(store.settings.gridColumns)", value: $store.settings.gridColumns, in: 2...5)
                    Toggle("Confirm app removal", isOn: $store.settings.confirmRemoval)
                    Toggle("Reduce shell motion", isOn: $store.settings.reduceShellMotion)
                }
                Section("Runtime") {
                    Label("LiveContainer bridge", systemImage: "bolt.horizontal.circle")
                    Text("The UI is ready for the native LiveContainer targets. Guest IPA execution requires its bootstrap, loader, extensions, entitlements, and signing/JIT setup.")
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
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .onChange(of: store.settings) { _, _ in
                store.settingsDidChange()
            }
        }
    }
}
