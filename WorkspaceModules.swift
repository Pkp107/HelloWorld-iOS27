import Foundation
import SwiftUI

/// The built-in developer surfaces exposed by Workspace.
///
/// This registry describes the UI and protocol surface. `WorkspaceModuleBundle`
/// is the authoritative source for whether an executable runtime is embedded,
/// whether an external asset is required, or whether work is remote-only.
enum WorkspaceModuleID: String, CaseIterable, Codable, Hashable, Identifiable {
    case java
    case c
    case cpp
    case dotnet
    case python
    case swiftObjectiveC
    case javascript
    case webAssembly
    case miniXcode
    case githubActions
    case macOSBuilder
    case windowsBuilder
    case raspberryPi
    case simulator
    case ipaSigner
    case liveContainer
    case debugger
    case frida
    case localhostServer
    case moonlight
    case sshDevelopment
    case mcpBridge
    case localAI
    case gitHubManager
    case fileManager
    case installerStore
    case jitSetup

    var id: String { rawValue }

    var title: String {
        switch self {
        case .java: return "Java"
        case .c: return "C"
        case .cpp: return "C++"
        case .dotnet: return "C# / .NET"
        case .python: return "Python"
        case .swiftObjectiveC: return "Swift & Objective-C"
        case .javascript: return "JavaScript / TypeScript"
        case .webAssembly: return "WebAssembly / WASI"
        case .miniXcode: return "Mini Xcode"
        case .githubActions: return "GitHub Actions"
        case .macOSBuilder: return "macOS iOS Builder"
        case .windowsBuilder: return "Windows EXE Builder"
        case .raspberryPi: return "Raspberry Pi Build Server"
        case .simulator: return "iOS Simulator Runner"
        case .ipaSigner: return "IPA Signer"
        case .liveContainer: return "LiveContainer Runtime"
        case .debugger: return "Debugger & Log Console"
        case .frida: return "Frida for LiveContainer Apps"
        case .localhostServer: return "Localhost Web Server"
        case .moonlight: return "Moonlight Remote Desktop"
        case .sshDevelopment: return "SSH Remote Development"
        case .mcpBridge: return "MCP Sandbox Bridge"
        case .localAI: return "Local AI Coding Assistant"
        case .gitHubManager: return "GitHub Manager"
        case .fileManager: return "Workspace File Manager"
        case .installerStore: return "Installer & Store"
        case .jitSetup: return "JIT Setup"
        }
    }

    var symbol: String {
        switch self {
        case .java: return "cup.and.saucer.fill"
        case .c, .cpp: return "chevron.left.forwardslash.chevron.right"
        case .dotnet: return "square.stack.3d.forward.dottedline"
        case .python: return "function"
        case .swiftObjectiveC: return "swift"
        case .javascript: return "curlybraces"
        case .webAssembly: return "shippingbox.fill"
        case .miniXcode: return "hammer.fill"
        case .githubActions, .gitHubManager: return "arrow.triangle.branch"
        case .macOSBuilder: return "laptopcomputer"
        case .windowsBuilder: return "desktopcomputer"
        case .raspberryPi: return "server.rack"
        case .simulator: return "iphone.gen3"
        case .ipaSigner: return "signature"
        case .liveContainer: return "shippingbox.and.arrow.backward.fill"
        case .debugger: return "ladybug.fill"
        case .frida: return "ant.fill"
        case .localhostServer: return "network"
        case .moonlight: return "gamecontroller.fill"
        case .sshDevelopment: return "terminal.fill"
        case .mcpBridge: return "point.3.connected.trianglepath.dotted"
        case .localAI: return "sparkles"
        case .fileManager: return "folder.fill"
        case .installerStore: return "bag.fill"
        case .jitSetup: return "bolt.horizontal.circle.fill"
        }
    }

    var category: String {
        switch self {
        case .java, .c, .cpp, .dotnet, .python, .swiftObjectiveC, .javascript, .webAssembly:
            return "Languages"
        case .miniXcode, .githubActions, .macOSBuilder, .windowsBuilder, .raspberryPi, .simulator:
            return "Build"
        case .ipaSigner, .liveContainer, .debugger, .frida, .jitSetup:
            return "iOS Runtime"
        case .localhostServer, .moonlight, .sshDevelopment, .mcpBridge, .localAI:
            return "Workspace"
        case .gitHubManager, .fileManager, .installerStore:
            return "Core"
        }
    }

    /// A user-facing indication of where the module's heavy work happens.
    var executionNote: String {
        switch WorkspaceModuleBundle.info(for: self).payload {
        case .embeddedRuntime: return "On device"
        case .embeddedAdapter: return "On-device adapter"
        case .externalAssetRequired: return "External asset"
        case .remoteOnly: return "Remote builder"
        }
    }

    var storageEstimate: String {
        switch self {
        case .miniXcode, .macOSBuilder, .windowsBuilder, .localAI: return "Large"
        case .java, .dotnet, .python, .swiftObjectiveC, .javascript, .webAssembly: return "Medium"
        default: return "Small"
        }
    }

    var summary: String {
        switch self {
        case .java: return "Edit Java projects and submit compilation to the configured build runner."
        case .c: return "Edit C projects and compile them on a configured remote builder."
        case .cpp: return "Edit C++ projects and compile them on a configured remote builder."
        case .dotnet: return "Edit .NET projects and publish them on a configured remote builder."
        case .python: return "Edit Python projects and run or package them on a configured builder."
        case .swiftObjectiveC: return "Edit Apple-language projects and send them to Xcode for builds."
        case .javascript: return "Build web, desktop, and native projects from one workspace."
        case .webAssembly: return "Portable sandbox for C, C++, Rust, and other compiled modules."
        case .miniXcode: return "Project editor with targets, build settings, logs, and artifacts."
        case .githubActions: return "Dispatch workflows, stream logs, and download build artifacts."
        case .macOSBuilder: return "Build simulator apps and signed device IPAs with Xcode."
        case .windowsBuilder: return "Build Windows executables with MSVC, MinGW, .NET, or packagers."
        case .raspberryPi: return "Coordinate jobs, cache dependencies, and host workspace services."
        case .simulator: return "Run simulator tests and inspect the resulting app bundle."
        case .ipaSigner: return "Sign an existing IPA with the configured certificate and profile."
        case .liveContainer: return "Run supported guest apps in the isolated LiveContainer workspace."
        case .debugger: return "Inspect logs and debug supported LiveContainer guest apps."
        case .frida: return "Instrument guest apps that are managed by LiveContainer."
        case .localhostServer: return "Host local HTTP and WebSocket development services."
        case .moonlight: return "Open a low-latency remote desktop or game-streaming session."
        case .sshDevelopment: return "Connect to the Pi, Mac, or Windows builder over SSH."
        case .mcpBridge: return "Expose authenticated workspace file tools on the local network."
        case .localAI: return "Chat UI for an imported model file; an iOS inference backend is still required."
        case .gitHubManager: return "Manage repositories, branches, commits, workflows, and artifacts."
        case .fileManager: return "Manage source, IPA, signing, and build files in app storage."
        case .installerStore: return "Browse repositories and choose signing or LiveContainer installs."
        case .jitSetup: return "Configure JIT providers and show setup diagnostics."
        }
    }
}

/// Persists the built-in module set independently of the workspace snapshot so
/// older snapshots remain readable and modules can evolve without migrations.
@MainActor
final class WorkspaceModuleStore: ObservableObject {
    @Published private(set) var enabled: Set<WorkspaceModuleID>

    private let defaultsKey = "workspace.enabledModules.v2"

    init() {
        // Expose every registered surface by default. This does not imply that
        // every heavy compiler, runtime, or model asset is embedded; the
        // payload inventory reports those requirements separately.
        let allModules = Set(WorkspaceModuleID.allCases)
        if let data = UserDefaults.standard.data(forKey: defaultsKey),
           let values = try? JSONDecoder().decode(Set<WorkspaceModuleID>.self, from: data) {
            enabled = values.union(allModules)
        } else {
            enabled = allModules
        }
        persist()
    }

    var modules: [WorkspaceModuleID] {
        WorkspaceModuleID.allCases.sorted {
            if $0.category != $1.category { return $0.category < $1.category }
            return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
        }
    }

    func isEnabled(_ module: WorkspaceModuleID) -> Bool {
        enabled.contains(module)
    }

    func setEnabled(_ value: Bool, for module: WorkspaceModuleID) {
        // Module installation was removed: all registered surfaces remain
        // active, while payload availability is reported by the inventory.
        enabled = Set(WorkspaceModuleID.allCases)
        persist()
    }

    func enableAll() {
        enabled = Set(WorkspaceModuleID.allCases)
        persist()
    }

    func disableOptional() {
        // Compatibility no-op retained for old callers.
        enabled = Set(WorkspaceModuleID.allCases)
        persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(enabled) else { return }
        UserDefaults.standard.set(data, forKey: defaultsKey)
    }
}

/// A downloaded module package is kept as an app-owned file.  iOS cannot load
/// an arbitrary unsigned Mach-O/framework downloaded after installation, so
/// this store records the package for data, scripts, model assets, and remote
/// adapters without pretending that it changes the signed executable.
struct WorkspaceInstalledModulePackage: Codable, Hashable, Identifiable {
    let moduleID: WorkspaceModuleID
    let version: String
    let fileName: String
    let sourceURL: URL
    let installedAt: Date

    var id: String { "\(moduleID.rawValue)@\(version)" }
}

@MainActor
final class WorkspaceModulePackageStore: ObservableObject {
    @Published private(set) var packages: [WorkspaceInstalledModulePackage]

    private let defaultsKey = "workspace.installedModulePackages.v1"

    init() {
        if let data = UserDefaults.standard.data(forKey: defaultsKey),
           let saved = try? JSONDecoder().decode([WorkspaceInstalledModulePackage].self, from: data) {
            packages = saved
        } else {
            packages = []
        }
    }

    func package(moduleID: WorkspaceModuleID, version: String) -> WorkspaceInstalledModulePackage? {
        packages.first { $0.moduleID == moduleID && $0.version == version }
    }

    func install(_ package: WorkspaceInstalledModulePackage) {
        packages.removeAll { $0.id == package.id }
        packages.append(package)
        packages.sort { $0.moduleID.title.localizedCaseInsensitiveCompare($1.moduleID.title) == .orderedAscending }
        persist()
    }

    func remove(_ package: WorkspaceInstalledModulePackage) {
        packages.removeAll { $0.id == package.id }
        persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(packages) else { return }
        UserDefaults.standard.set(data, forKey: defaultsKey)
    }
}
