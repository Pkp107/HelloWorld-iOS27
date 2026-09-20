import SwiftUI

struct ContentView: View {
    @ObservedObject var store: WorkspaceStore
    @State private var destination: WorkspaceDestination?
    @State private var runtimeApp: VirtualApp?
    @State private var folder: VirtualFolder?
    @State private var showingImporter = false

    var body: some View {
        ZStack {
            Color(uiColor: .systemGroupedBackground)
                .ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    WorkspaceHeader(
                        sessionCount: store.sessions.count,
                        onLibrary: { destination = .library },
                        onTasks: { destination = .tasks },
                        onSettings: { destination = .settings }
                    )

                    HomeGrid(
                        apps: store.homeApps,
                        folders: store.folders,
                        columns: store.settings.gridColumns,
                        showLabels: store.settings.showAppLabels,
                        onOpenApp: open,
                        onOpenFolder: { folder = $0 }
                    )
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, 120)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            WorkspaceDock(
                pinnedApps: store.pinnedApps,
                onOpenApp: open,
                onLibrary: { destination = .library },
                onTasks: { destination = .tasks }
            )
            .padding(.horizontal, 18)
            .padding(.bottom, 8)
        }
        .sheet(item: $destination) { destination in
            switch destination {
            case .library:
                AppLibraryView(store: store, onOpen: open, onImport: { showingImporter = true })
            case .tasks:
                TaskSwitcherView(store: store, onOpen: open)
            case .settings:
                SettingsView(store: store)
            }
        }
        .sheet(item: $runtimeApp) { app in
            RuntimeWindow(app: app, store: store)
        }
        .sheet(item: $folder) { folder in
            FolderView(folder: folder, store: store, onOpen: open)
        }
        .fileImporter(isPresented: $showingImporter, allowedContentTypes: [.ipa, .zip, .data], allowsMultipleSelection: false) { result in
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

    private func open(_ app: VirtualApp) {
        store.open(app)
        runtimeApp = app
    }
}

private enum WorkspaceDestination: String, Identifiable {
    case library, tasks, settings
    var id: String { rawValue }
}

private struct WorkspaceHeader: View {
    let sessionCount: Int
    let onLibrary: () -> Void
    let onTasks: () -> Void
    let onSettings: () -> Void

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text("HelloOS")
                    .font(.largeTitle.weight(.bold))
                Text(Date.now, format: .dateTime.weekday(.wide).month(.wide).day())
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            HStack(spacing: 8) {
                WorkspaceIconButton(symbol: "square.grid.2x2", label: "App library", action: onLibrary)
                WorkspaceIconButton(symbol: "rectangle.stack", label: "Task switcher", badge: sessionCount, action: onTasks)
                WorkspaceIconButton(symbol: "gearshape", label: "Settings", action: onSettings)
            }
        }
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
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Workspace")
                    .font(.title2.weight(.bold))
                Spacer()
                Text("\(apps.count + folders.count) items")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
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
        .accessibilityHint(app.isBuiltIn ? "Opens the built-in app" : "Opens app details and runtime status")
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
    let onLibrary: () -> Void
    let onTasks: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            ForEach(pinnedApps.prefix(3)) { app in
                AppDockButton(app: app, action: { onOpenApp(app) })
            }
            Divider().frame(height: 30)
            WorkspaceIconButton(symbol: "square.grid.2x2", label: "App library", action: onLibrary)
            WorkspaceIconButton(symbol: "rectangle.stack", label: "Task switcher", action: onTasks)
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

private struct WorkspaceIconButton: View {
    let symbol: String
    let label: String
    var badge: Int = 0
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack(alignment: .topTrailing) {
                Image(systemName: symbol)
                    .font(.system(size: 17, weight: .semibold))
                    .frame(width: 44, height: 44)
                    .background(.secondary.opacity(0.12), in: Circle())
                if badge > 0 {
                    Text("\(badge)")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.white)
                        .padding(4)
                        .background(.blue, in: Capsule())
                        .offset(x: 3, y: -3)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityValue(badge > 0 ? "\(badge) open" : "")
    }
}

private struct RuntimeWindow: View {
    let app: VirtualApp
    @ObservedObject var store: WorkspaceStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if app.isBuiltIn {
                    BuiltInHelloWorldView()
                } else {
                    ImportedRuntimeView(app: app, store: store)
                }
            }
            .navigationTitle(app.displayName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        store.suspend(app)
                        dismiss()
                    }
                }
            }
        }
    }
}

private struct BuiltInHelloWorldView: View {
    @State private var didTap = false

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "hand.wave.fill")
                .font(.system(size: 56, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            VStack(spacing: 8) {
                Text("Hello, world!")
                    .font(.largeTitle.weight(.bold))
                Text(didTap ? "Thanks for saying hello." : "The first built-in HelloOS app.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            Button("Say hello") { didTap = true }
                .font(.body.weight(.semibold))
                .frame(minWidth: 140, minHeight: 44)
                .buttonStyle(.borderedProminent)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(uiColor: .systemBackground))
    }
}

private struct ImportedRuntimeView: View {
    let app: VirtualApp
    @ObservedObject var store: WorkspaceStore

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: app.iconSymbol)
                .font(.system(size: 48, weight: .semibold))
                .foregroundStyle(Color.workspaceAccent(app.iconColor))
            Text("Managed app")
                .font(.title2.weight(.bold))
                .multilineTextAlignment(.center)
            Text("\(app.displayName) is stored in HelloOS. The native LiveContainer runtime is not embedded in this target yet, so this IPA is managed but cannot execute here yet.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 330)
            Label("Runtime unavailable", systemImage: "exclamationmark.triangle")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.orange)
            Button("Close session") {
                store.close(app)
            }
            .buttonStyle(.bordered)
            .frame(minHeight: 44)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
