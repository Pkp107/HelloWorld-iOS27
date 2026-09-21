import Foundation
import SwiftUI

/// The optional developer modules that can be installed into Workspace.
///
/// The registry is deliberately metadata-only: it records the user's module
/// choices and gives the UI a stable place to attach installers later. Heavy
/// toolchains are downloaded by their owning module instead of being bundled
/// into the Workspace application.
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
        switch self {
        case .java, .c, .cpp, .dotnet, .python, .webAssembly, .localAI:
            return "On device"
        case .swiftObjectiveC, .javascript:
            return "On device and remote"
        case .miniXcode, .githubActions, .macOSBuilder, .windowsBuilder, .raspberryPi, .simulator:
            return "Remote build"
        case .ipaSigner, .liveContainer, .debugger, .frida, .jitSetup, .localhostServer, .fileManager, .installerStore:
            return "On device"
        case .moonlight, .sshDevelopment, .mcpBridge, .gitHubManager:
            return "Network"
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
        case .java: return "Compile and run Java bytecode; native packaging uses the configured build runner."
        case .c: return "Compile C to WASI locally or to a Windows/iOS target remotely."
        case .cpp: return "Compile C++ to WASI locally or to a Windows/iOS target remotely."
        case .dotnet: return "Run managed .NET programs locally and publish native targets remotely."
        case .python: return "Run Python projects locally and package them with the selected build runner."
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
        case .localAI: return "Run an optional on-device coding model with downloaded weights."
        case .gitHubManager: return "Manage repositories, branches, commits, workflows, and artifacts."
        case .fileManager: return "Manage source, IPA, signing, and build files in app storage."
        case .installerStore: return "Browse repositories and choose signing or LiveContainer installs."
        case .jitSetup: return "Configure JIT providers and show setup diagnostics."
        }
    }
}

/// Persists optional module choices independently of the workspace snapshot so
/// older snapshots remain readable and modules can evolve without migrations.
@MainActor
final class WorkspaceModuleStore: ObservableObject {
    @Published private(set) var enabled: Set<WorkspaceModuleID>

    private let defaultsKey = "workspace.enabledModules.v1"

    init() {
        if let data = UserDefaults.standard.data(forKey: defaultsKey),
           let values = try? JSONDecoder().decode(Set<WorkspaceModuleID>.self, from: data) {
            enabled = values
        } else {
            enabled = Set([
                .miniXcode, .githubActions, .gitHubManager,
                .fileManager, .installerStore, .liveContainer, .jitSetup
            ])
        }
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
        if value {
            enabled.insert(module)
        } else {
            enabled.remove(module)
        }
        persist()
    }

    func enableAll() {
        enabled = Set(WorkspaceModuleID.allCases)
        persist()
    }

    func disableOptional() {
        enabled = Set([.miniXcode, .githubActions, .gitHubManager, .fileManager, .installerStore, .liveContainer, .jitSetup])
        persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(enabled) else { return }
        UserDefaults.standard.set(data, forKey: defaultsKey)
    }
}

struct WorkspaceModulesView: View {
    @ObservedObject var store: WorkspaceModuleStore

    private var enabledCount: Int { store.enabled.count }

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Add the tools you need")
                        .font(.headline)
                    Text("Large runtimes are optional. Workspace keeps your choices here and downloads each module when its installer is available.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    ProgressView(value: Double(enabledCount), total: Double(WorkspaceModuleID.allCases.count)) {
                        Text("\(enabledCount) of \(WorkspaceModuleID.allCases.count) enabled")
                    }
                }
                .padding(.vertical, 4)
            }

            ForEach(store.modules) { module in
                Section(module.category) {
                    moduleRow(module)
                }
            }

            Section("Quick actions") {
                Button("Enable all modules") { store.enableAll() }
                Button("Keep core modules only") { store.disableOptional() }
            }
        }
        .navigationTitle("Modules")
    }

    private func moduleRow(_ module: WorkspaceModuleID) -> some View {
        Toggle(isOn: Binding(
            get: { store.isEnabled(module) },
            set: { store.setEnabled($0, for: module) }
        )) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: module.symbol)
                    .font(.title3)
                    .foregroundStyle(.tint)
                    .frame(width: 26)
                VStack(alignment: .leading, spacing: 3) {
                    Text(module.title)
                        .font(.body.weight(.medium))
                    Text(module.summary)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 8) {
                        Label(module.executionNote, systemImage: "location.fill")
                        Label(module.storageEstimate, systemImage: "internaldrive")
                    }
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                }
            }
        )
        .accessibilityHint("Enable or disable the \(module.title) module")
    }
}
