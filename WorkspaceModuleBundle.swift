import Foundation

/// Describes the payload that is actually present in the signed Workspace
/// application.  A module can have a native UI/adapter in the IPA while its
/// heavy executable (for example Xcode, MSVC, or model weights) remains on a
/// remote builder or is imported by the user.
enum WorkspaceModulePayloadKind: String, Codable, CaseIterable, Hashable {
    /// Swift/Objective-C code and the supporting native framework are in the
    /// application bundle and can run on the device.
    case embeddedRuntime
    /// The UI and protocol adapter ship in the application, but the work is
    /// performed by another process, device, or service.
    case embeddedAdapter
    /// No local toolchain is shipped; the module submits work to a builder.
    case remoteOnly
    /// A runtime can be used only after the user imports a large asset such as
    /// a model file.  The asset is intentionally not copied into the IPA.
    case externalAssetRequired
}

struct WorkspaceModuleBundleInfo: Codable, Hashable, Identifiable {
    let id: WorkspaceModuleID
    let payload: WorkspaceModulePayloadKind
    let artifactDescription: String
    let externalAssetHint: String?

    var isPresentInIPA: Bool {
        payload == .embeddedRuntime || payload == .embeddedAdapter
    }

    var requiresExternalAsset: Bool {
        payload == .externalAssetRequired
    }
}

/// The truthful, lightweight inventory used by diagnostics and the MCP
/// capability response.  It is deliberately code-only; model weights and
/// desktop SDKs must never be represented as if they were bundled.
enum WorkspaceModuleBundle {
    static let infos: [WorkspaceModuleBundleInfo] = WorkspaceModuleID.allCases.map { id in
        switch id {
        case .ipaSigner:
            return .init(id: id, payload: .embeddedRuntime,
                         artifactDescription: "Native IPA signing bridge and signing UI are bundled in the integrated build.",
                         externalAssetHint: "A valid P12 and mobileprovision are still required.")
        case .liveContainer:
            return .init(id: id, payload: .embeddedRuntime,
                         artifactDescription: "The pinned LiveContainer host is bundled by the integrated build.",
                         externalAssetHint: "Guest IPAs and their data are imported after installation.")
        case .debugger, .frida:
            return .init(id: id, payload: .embeddedAdapter,
                         artifactDescription: "Workspace inspector, log console, and guest bridge adapters are bundled.",
                         externalAssetHint: "The guest must opt in to Gadget instrumentation before semantic control is available.")
        case .localhostServer, .mcpBridge, .fileManager, .installerStore, .jitSetup,
             .moonlight, .sshDevelopment, .gitHubManager, .githubActions,
             .miniXcode:
            return .init(id: id, payload: .embeddedAdapter,
                         artifactDescription: "The on-device UI, protocol client, and authenticated bridge are bundled.",
                         externalAssetHint: nil)
        case .localAI:
            return .init(id: id, payload: .externalAssetRequired,
                         artifactDescription: "The AI chat UI and model registry are bundled; no model weights are in the IPA.",
                         externalAssetHint: "Import a compatible model file (for example GGUF) and provide an inference backend.")
        case .java, .c, .cpp, .dotnet, .python, .swiftObjectiveC, .javascript, .webAssembly,
             .macOSBuilder, .windowsBuilder, .raspberryPi, .simulator:
            return .init(id: id, payload: .remoteOnly,
                         artifactDescription: "The editor and job connector are bundled; the compiler/toolchain runs on a configured builder.",
                         externalAssetHint: "Configure GitHub Actions, macOS, Windows, Raspberry Pi, or another supported builder.")
        }
    }

    static func info(for id: WorkspaceModuleID) -> WorkspaceModuleBundleInfo {
        infos.first(where: { $0.id == id })!
    }

    static var embeddedCount: Int {
        infos.filter(\.isPresentInIPA).count
    }

    static var externalAssetCount: Int {
        infos.filter(\.requiresExternalAsset).count
    }

    /// A serializable diagnostics payload suitable for the MCP bridge.
    static var diagnostics: [[String: Any]] {
        infos.map { info in
            [
                "id": info.id.rawValue,
                "title": info.id.title,
                "payload": info.payload.rawValue,
                "present_in_ipa": info.isPresentInIPA,
                "requires_external_asset": info.requiresExternalAsset,
                "description": info.artifactDescription,
                "external_asset_hint": info.externalAssetHint ?? NSNull()
            ]
        }
    }
}
