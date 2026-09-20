#if LIVE_CONTAINER_NATIVE
import SwiftUI

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

struct NativeLiveContainerSignerView: View {
    @EnvironmentObject private var sharedModel: SharedModel
    @State private var selectedID: ObjectIdentifier?
    @State private var statusMessage: String?

    private var selectedApp: LCAppModel? {
        sharedModel.apps.first { ObjectIdentifier($0) == selectedID }
    }

    var body: some View {
        NavigationStack {
            List {
                Section("Installed apps") {
                    if sharedModel.apps.isEmpty {
                        ContentUnavailableView(
                            "No installed apps",
                            systemImage: "shippingbox",
                            description: Text("Import an IPA from Installer first.")
                        )
                    } else {
                        ForEach(sharedModel.apps, id: \.self) { app in
                            Button {
                                selectedID = ObjectIdentifier(app)
                            } label: {
                                Label(app.appInfo.displayName(), systemImage: "shippingbox.fill")
                                    .foregroundStyle(.primary)
                            }
                            .listRowBackground(
                                selectedID == ObjectIdentifier(app)
                                    ? Color.accentColor.opacity(0.14)
                                    : nil
                            )
                        }
                    }
                }

                Section {
                    Button("Sign selected app") {
                        signSelectedApp()
                    }
                    .disabled(selectedApp == nil)
                    Text("LiveContainer uses its native ZSign path and the host certificate configured in Settings. The private-key password is requested by the native signer when needed.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("IPA Signer")
        }
        .environmentObject(sharedModel)
        .alert("Signing", isPresented: Binding(
            get: { statusMessage != nil },
            set: { if !$0 { statusMessage = nil } }
        )) {
            Button("OK", role: .cancel) { statusMessage = nil }
        } message: {
            Text(statusMessage ?? "")
        }
    }

    private func signSelectedApp() {
        guard let selectedApp else { return }
        Task {
            do {
                try await selectedApp.forceResign()
                await MainActor.run {
                    statusMessage = "Signing completed for \(selectedApp.appInfo.displayName())."
                }
            } catch {
                await MainActor.run {
                    statusMessage = "Signing failed: \(error.localizedDescription)"
                }
            }
        }
    }
}
#endif
