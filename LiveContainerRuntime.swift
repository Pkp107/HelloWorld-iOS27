import Foundation

/// Describes what the current target can see at compile time.
///
/// The native build is assembled from the upstream LiveContainer targets;
/// the lightweight target retains the same status boundary without claiming
/// that it can launch guest processes.
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

/// Reports the capability of the current build without making the fallback
/// target look like a guest-app runtime.
struct LiveContainerRuntime: LiveContainerRuntimeBridge {
    static let shared = LiveContainerRuntime()

    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    var availability: RuntimeAvailability {
#if LIVE_CONTAINER_NATIVE || canImport(LiveContainerShared)
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

#if LIVE_CONTAINER_NATIVE || canImport(LiveContainerShared)
#if LIVE_CONTAINER_NATIVE
        return LiveContainerRuntimeReport(
            availability: availability,
            state: .nativeExecutionReady,
            signing: .hostCertificateRequired,
            storedIPAURL: ipaURL,
            message: "Native LiveContainer is available. Import and launch this guest from the Installer or Installed Apps surface."
        )
#else
        return LiveContainerRuntimeReport(
            availability: availability,
            state: .managedOnly,
            signing: .hostCertificateRequired,
            storedIPAURL: ipaURL,
            message: "IPA found. This lightweight build can manage the file, but it does not include the native LiveContainer host."
        )
#endif
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
