#if LIVE_CONTAINER_NATIVE
import SwiftUI
import UIKit

/// Reuses LiveContainer's existing Share Extension while routing signing
/// assets into Workspace's shared signing store.
struct WorkspaceShareRootView: View {
    @ObservedObject var viewModel: ShareExtensionViewModel
    let extensionContext: NSExtensionContext?

    var body: some View {
        if let fileURL = sharedFileURL, let kind = SigningShareKind(fileURL: fileURL) {
            WorkspaceSigningAssetShareView(
                fileURL: fileURL,
                kind: kind,
                extensionContext: extensionContext
            )
        } else {
            ShareExtensionRootView(viewModel: viewModel, extensionContext: extensionContext)
        }
    }

    private var sharedFileURL: URL? {
        guard case .file(let url) = viewModel.payload.kind else { return nil }
        return url
    }
}

private enum SigningShareKind: String {
    case certificate
    case provisioningProfile
    case aiModel

    init?(fileURL: URL) {
        switch fileURL.pathExtension.lowercased() {
        case "p12", "pfx": self = .certificate
        case "mobileprovision", "provisionprofile": self = .provisioningProfile
        case "gguf", "ggml", "safetensors", "mlmodel", "mlmodelc", "mlpackage", "onnx", "bin", "model": self = .aiModel
        default: return nil
        }
    }

    var title: String {
        switch self {
        case .certificate: return "Certificate"
        case .provisioningProfile: return "Provisioning profile"
        case .aiModel: return "AI model"
        }
    }
}

private struct WorkspaceSigningAssetShareView: View {
    let fileURL: URL
    let kind: SigningShareKind
    let extensionContext: NSExtensionContext?
    @State private var errorMessage: String?
    @State private var isSaving = false

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 18) {
                Label("Add to Workspace", systemImage: "square.and.arrow.down")
                    .font(.title2.weight(.semibold))
            Text(kind == .aiModel
                 ? "Save this model to Workspace Files so the AI app can use it without the Files picker."
                 : "Save this \(kind.title.lowercased()) for IPA Signer and certificate-based JIT.")
                    .foregroundStyle(.secondary)
                LabeledContent("File", value: fileURL.lastPathComponent)
                    .lineLimit(2)
                Spacer()
                Button(isSaving ? "Saving..." : "Save to Workspace") {
                    save()
                }
                .buttonStyle(.borderedProminent)
                .disabled(isSaving)
                .frame(maxWidth: .infinity)
            }
            .padding(22)
            .navigationTitle("Workspace")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { extensionContext?.cancelRequest(withError: WorkspaceShareError("Cancelled")) }
                }
            }
            .alert("Could not save file", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    private func save() {
        isSaving = true
        defer { isSaving = false }
        let accessed = fileURL.startAccessingSecurityScopedResource()
        defer { if accessed { fileURL.stopAccessingSecurityScopedResource() } }

        do {
            guard let appGroupPath = LCSharedUtils.appGroupPath() else {
                throw WorkspaceShareError("Workspace shared storage is unavailable.")
            }
            let directory: URL
            if kind == .aiModel {
                // Keep shared imports under the same root that the main app's
                // file manager exposes. This makes Share -> Workspace files
                // immediately selectable by the AI app.
                directory = appGroupPath.appendingPathComponent("Workspace-iOS27/Workspace Files/AI Models", isDirectory: true)
            } else {
                directory = appGroupPath
                    .appendingPathComponent("Workspace-iOS27/Signing/Incoming", isDirectory: true)
                    .appendingPathComponent(kind.rawValue, isDirectory: true)
            }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let destination = directory.appendingPathComponent(fileURL.lastPathComponent, isDirectory: false)
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.copyItem(at: fileURL, to: destination)
            extensionContext?.completeRequest(returningItems: nil, completionHandler: nil)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct WorkspaceShareError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
#endif
