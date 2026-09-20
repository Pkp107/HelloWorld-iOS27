import Foundation

/// Describes what the current target can see at compile time.
///
/// `nativeFrameworkDetected` only means that a LiveContainer module can be
/// imported by this target. It does not mean that guest execution is wired.
enum RuntimeAvailability: String, Codable, CaseIterable {
    case unavailable
    case nativeFrameworkDetected

    var label: String {
        switch self {
        case .unavailable:
            return "Native LiveContainer runtime unavailable"
        case .nativeFrameworkDetected:
            return "LiveContainer framework detected"
        }
    }

    var hasNativeFramework: Bool {
        self == .nativeFrameworkDetected
    }
}

/// The states exposed to the workspace UI for a stored app.
///
/// `nativeExecutionReady` is reserved for a future adapter that actually
/// invokes the upstream bootstrap. The current target never returns it.
enum LiveContainerExecutionState: String, Codable, CaseIterable {
    case builtIn
    case ipaMissing
    case managedOnly
    case runtimeUnavailable
    case nativeExecutionReady

    var label: String {
        switch self {
        case .builtIn:
            return "Built-in app"
        case .ipaMissing:
            return "IPA file missing"
        case .managedOnly:
            return "Managed locally"
        case .runtimeUnavailable:
            return "Runtime unavailable"
        case .nativeExecutionReady:
            return "Ready to run"
        }
    }

    var canExecuteImportedIPA: Bool {
        self == .nativeExecutionReady
    }
}

/// Signing is tracked separately because signing the host IPA does not sign
/// or authorize an imported guest IPA.
enum LiveContainerSigningState: String, Codable, CaseIterable {
    case notRequired
    case unavailable
    case hostCertificateRequired

    var label: String {
        switch self {
        case .notRequired:
            return "Signing not required"
        case .unavailable:
            return "Signing unavailable"
        case .hostCertificateRequired:
            return "Host certificate required"
        }
    }
}

struct LiveContainerRuntimeReport: Equatable {
    let availability: RuntimeAvailability
    let state: LiveContainerExecutionState
    let signing: LiveContainerSigningState
    let storedIPAURL: URL?
    let message: String

    var canExecuteImportedIPA: Bool {
        state.canExecuteImportedIPA
    }
}

protocol LiveContainerRuntimeBridge {
    var availability: RuntimeAvailability { get }

    func inspect(ipaURL: URL?, isBuiltIn: Bool) -> LiveContainerRuntimeReport
}

/// Small boundary for the eventual native LiveContainer integration.
///
/// LiveContainer's real execution path is a collection of native targets
/// (bootstrap, shared framework, loader, extensions, and entitlements). This
/// app deliberately does not vendor those targets, so imported IPAs remain
/// managed files until a concrete native adapter is added.
struct LiveContainerRuntime: LiveContainerRuntimeBridge {
    static let shared = LiveContainerRuntime()

    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    var availability: RuntimeAvailability {
#if canImport(LiveContainerShared)
        return .nativeFrameworkDetected
#else
        return .unavailable
#endif
    }

    func inspect(ipaURL: URL?, isBuiltIn: Bool = false) -> LiveContainerRuntimeReport {
        if isBuiltIn {
            return LiveContainerRuntimeReport(
                availability: availability,
                state: .builtIn,
                signing: .notRequired,
                storedIPAURL: nil,
                message: "Built into the workspace and runs locally."
            )
        }

        guard let ipaURL else {
            return LiveContainerRuntimeReport(
                availability: availability,
                state: .ipaMissing,
                signing: .unavailable,
                storedIPAURL: nil,
                message: "No stored IPA was provided."
            )
        }

        guard fileManager.fileExists(atPath: ipaURL.path) else {
            return LiveContainerRuntimeReport(
                availability: availability,
                state: .ipaMissing,
                signing: .unavailable,
                storedIPAURL: ipaURL,
                message: "The stored IPA is no longer present on disk."
            )
        }

#if canImport(LiveContainerShared)
        return LiveContainerRuntimeReport(
            availability: availability,
            state: .managedOnly,
            signing: .hostCertificateRequired,
            storedIPAURL: ipaURL,
            message: "IPA found. A native launch adapter still needs to bind the LiveContainer bootstrap."
        )
#else
        return LiveContainerRuntimeReport(
            availability: availability,
            state: .runtimeUnavailable,
            signing: .unavailable,
            storedIPAURL: ipaURL,
            message: "IPA found, but this build does not include the native LiveContainer targets."
        )
#endif
    }

    /// Resolves the same application-support location used by WorkspaceStore.
    func storedIPAURL(fileName: String) -> URL {
        fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Workspace", isDirectory: true)
            .appendingPathComponent("Imports", isDirectory: true)
            .appendingPathComponent(fileName, isDirectory: false)
    }
}
