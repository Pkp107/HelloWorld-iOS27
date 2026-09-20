import SwiftUI

struct ContentView: View {
    @ObservedObject var store: WorkspaceStore
    @State private var activeApp: VirtualApp?
    @State private var folder: VirtualFolder?

    var body: some View {
        ZStack {
            Color(uiColor: .systemGroupedBackground)
                .ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    HomeHeader(itemCount: store.homeApps.count + store.folders.count)
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
            AppLibraryView(store: store, onOpen: onOpen)
        case .settings:
            SettingsView(store: store)
        case .ipaSigner:
            IPASignerView(store: store)
        case nil:
            ImportedRuntimeView(app: app, store: store)
        }
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
