import SwiftUI

/// The offline help center for Workspace. Content is bundled with the app so
/// the user can recover from setup problems even when the network is down.
struct WorkspaceHelpView: View {
    @ObservedObject var store: WorkspaceStore
    let onOpen: (VirtualApp) -> Void
    @State private var searchText = ""
    @State private var showingLimits = false

    private var topics: [WorkspaceHelpTopic] {
        WorkspaceHelpTopic.all.filter { topic in
            searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
            topic.searchText.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 10) {
                        Label("Workspace Help", systemImage: "questionmark.circle.fill")
                            .font(.title2.weight(.bold))
                        Text("Offline guides for setting up Workspace, installing apps, working with modules, and fixing common problems.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Text("iOS 27 · Workspace guide 1.0")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, 6)
                }

                Section("Quick start") {
                    HelpActionRow(title: "First-time setup", subtitle: "Wallpaper, folders, signing assets, JIT, and optional services", symbol: "sparkles", color: .orange) {
                        WorkspaceHelpTopicView(topic: .quickStart, store: store, onOpen: onOpen)
                    }
                    HelpActionRow(title: "Set up an AI model", subtitle: "Share model files into Workspace Files / AI Models", symbol: "brain.head.profile", color: .purple) {
                        WorkspaceHelpTopicView(topic: .aiModels, store: store, onOpen: onOpen)
                    }
                    HelpActionRow(title: "Build with GitHub Actions", subtitle: "Run the iOS 27 workflow and download its artifact", symbol: "arrow.triangle.branch", color: .indigo) {
                        WorkspaceHelpTopicView(topic: .githubActions, store: store, onOpen: onOpen)
                    }
                }

                Section("Guides") {
                    ForEach(topics) { topic in
                        NavigationLink {
                            WorkspaceHelpTopicView(topic: topic, store: store, onOpen: onOpen)
                        } label: {
                            HelpTopicRow(topic: topic)
                        }
                    }
                }

                Section("Quick fixes") {
                    NavigationLink {
                        WorkspaceHelpTopicView(topic: .troubleshooting, store: store, onOpen: onOpen)
                    } label: {
                        Label("Troubleshooting center", systemImage: "wrench.and.screwdriver.fill")
                    }
                    Button {
                        showingLimits = true
                    } label: {
                        Label("What stock iOS cannot do", systemImage: "exclamationmark.triangle.fill")
                    }
                    .foregroundStyle(.orange)
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Help")
            .searchable(text: $searchText, prompt: "Search help")
            .sheet(isPresented: $showingLimits) {
                NavigationStack {
                    WorkspaceHelpTopicView(topic: .limits, store: store, onOpen: onOpen)
                        .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { showingLimits = false } } }
                }
            }
        }
    }

}

private struct HelpActionRow<Destination: View>: View {
    let title: String
    let subtitle: String
    let symbol: String
    let color: Color
    let destination: Destination

    init(title: String, subtitle: String, symbol: String, color: Color, @ViewBuilder destination: () -> Destination) {
        self.title = title
        self.subtitle = subtitle
        self.symbol = symbol
        self.color = color
        self.destination = destination()
    }

    var body: some View {
        NavigationLink { destination } label: {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .font(.headline)
                    .foregroundStyle(.white)
                    .frame(width: 38, height: 38)
                    .background(color, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.body.weight(.semibold))
                    Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            .padding(.vertical, 3)
        }
    }
}

private struct HelpTopicRow: View {
    let topic: WorkspaceHelpTopic

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: topic.symbol)
                .foregroundStyle(topic.color)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(topic.title).font(.body.weight(.semibold))
                Text(topic.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
        }
        .padding(.vertical, 3)
    }
}

private struct WorkspaceHelpTopicView: View {
    let topic: WorkspaceHelpTopic
    @ObservedObject var store: WorkspaceStore
    let onOpen: (VirtualApp) -> Void

    var body: some View {
        List {
            Section {
                Text(topic.introduction)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 4)
            }

            Section("Steps") {
                ForEach(Array(topic.steps.enumerated()), id: \.offset) { index, step in
                    HStack(alignment: .top, spacing: 12) {
                        Text("\(index + 1)")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.white)
                            .frame(width: 24, height: 24)
                            .background(topic.color, in: Circle())
                        VStack(alignment: .leading, spacing: 4) {
                            Text(step.title).font(.body.weight(.semibold))
                            Text(step.body).font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 5)
                }
            }

            if let destination = topic.destination,
               let app = store.apps.first(where: { $0.systemApp == destination }) {
                Section {
                    Button {
                        onOpen(app)
                    } label: {
                        Label("Open \(app.displayName)", systemImage: destination.iconSymbol)
                    }
                }
            }

            if let note = topic.note {
                Section("Keep in mind") {
                    Label(note, systemImage: "info.circle")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(topic.title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct WorkspaceHelpStep: Hashable {
    let title: String
    let body: String
}

private struct WorkspaceHelpTopic: Identifiable, Hashable {
    let id: String
    let title: String
    let subtitle: String
    let introduction: String
    let symbol: String
    let color: Color
    let steps: [WorkspaceHelpStep]
    let destination: SystemAppKind?
    let note: String?

    var searchText: String { ([title, subtitle, introduction] + steps.map { $0.title + " " + $0.body }).joined(separator: " ") }

    static let all: [WorkspaceHelpTopic] = [.quickStart, .basics, .installer, .modules, .signing, .liveContainer, .aiModels, .githubActions, .developerTools, .networking, .troubleshooting, .privacy, .limits]

    static let quickStart = WorkspaceHelpTopic(
        id: "quick-start", title: "First-time setup", subtitle: "Get Workspace ready in a few minutes", introduction: "Complete these steps in order. You can return to Settings or Help at any time.", symbol: "sparkles", color: .orange,
        steps: [
            .init(title: "Choose your look", body: "Open Settings > Customization > Background and choose a wallpaper. Home Screen controls the grid, labels, and removal confirmation."),
            .init(title: "Use Workspace Files", body: "Open File Manager to see the app-owned folders. Use Share > Workspace for IPAs, P12 files, mobileprovision files, and model weights when the system picker does not respond."),
            .init(title: "Configure signing and JIT", body: "Open Settings > Signing and JIT. Import a P12 and matching mobileprovision, enter the certificate password, and select a supported JIT provider."),
            .init(title: "Pick an install path", body: "Installer > Store lets you choose Sign & Install or LiveContainer. LiveContainer guests appear in Installed and on the Workspace home screen."),
            .init(title: "Add optional services", body: "Set up GitHub Actions, the local network server, MCP, and an AI model only when you need them. Each has a guide here."),
        ], destination: .settings, note: "Workspace keeps guides offline. Network downloads, JIT, signing, and model inference depend on iOS, device, profile, and service availability.")

    static let basics = WorkspaceHelpTopic(
        id: "basics", title: "Workspace basics", subtitle: "Home, folders, dock, and files", introduction: "Workspace is a fixed home surface around the tools and LiveContainer guests you choose to keep visible.", symbol: "square.grid.2x2.fill", color: .blue,
        steps: [
            .init(title: "Open an app", body: "Tap an icon or a dock item. The edge home bar remains available while an app is open; its side changes with orientation."),
            .init(title: "Reorder icons", body: "Long-press and drag an icon onto another icon. The new order is saved when you release it."),
            .init(title: "Remove a guest", body: "Use an imported app's context menu and choose Remove app. Built-in Workspace tools cannot be removed; guest data and its stored IPA may be deleted."),
            .init(title: "Manage files", body: "File Manager shows the current folder path and lets you copy, move, rename, share, and delete app-owned files."),
        ], destination: .fileManager, note: "The home surface does not scroll. If there are more icons than fit, use folders or adjust the Home Screen grid in Settings.")

    static let installer = WorkspaceHelpTopic(
        id: "installer", title: "Installer and App Store", subtitle: "Browse, inspect, and install IPAs", introduction: "Installer combines the store, repository list, installed LiveContainer guests, signing flow, and module downloads.", symbol: "bag.fill", color: .orange,
        steps: [
            .init(title: "Browse the Store", body: "Use search and sorting to find an app. Open its detail page to see name, category, repository origin, size, version, and install options."),
            .init(title: "Add a repository", body: "Open Repos, tap +, and enter an HTTPS AltStore/SideStore-compatible JSON feed. Only add sources you trust."),
            .init(title: "Choose the install method", body: "Tap Install, then choose Sign & Install for an iOS Home Screen install or LiveContainer to keep the guest inside Workspace."),
            .init(title: "Check Installed", body: "Installed lists only apps installed through LiveContainer. Signed apps are managed by iOS and are not listed there."),
            .init(title: "Import a local IPA", body: "Share the IPA to Workspace or copy it into Workspace Files / IPAs, then select it in Installer."),
        ], destination: .installer, note: "A valid IPA alone is not enough for a Home Screen install: the certificate, provisioning profile, device, bundle ID, entitlements, and iOS trust state must agree.")

    static let modules = WorkspaceHelpTopic(
        id: "modules", title: "GitHub modules", subtitle: "Fetch optional packages from modules.json", introduction: "The Modules tab reads a public GitHub modules.json feed and keeps downloaded packages in Workspace Files / Modules.", symbol: "shippingbox", color: .purple,
        steps: [
            .init(title: "Publish a feed", body: "Commit a modules.json file to a GitHub repository. Each entry needs a known Workspace module id, version, title, summary, payload, and an HTTPS GitHub download URL or assetName."),
            .init(title: "Set the feed URL", body: "Open Installer > Modules. The default feed is the Workspace repository. Use Save to enter another HTTPS raw GitHub URL or a GitHub repository URL."),
            .init(title: "Refresh", body: "Tap the refresh button. Unsupported IDs, non-GitHub URLs, invalid JSON, and non-HTTPS downloads are rejected with a visible status message."),
            .init(title: "Download", body: "Tap Get. Downloads are capped at 2 GB, optionally checked against sha256, atomically moved into Workspace Files / Modules, and recorded in the package list."),
        ], destination: .installer, note: "Downloaded packages are app-owned data. Stock iOS cannot dynamically execute arbitrary unsigned Mach-O, compiler, runtime, or framework binaries after installation. Use signed built-in adapters, model/data assets, or remote builders.")

    static let signing = WorkspaceHelpTopic(
        id: "signing", title: "Signing and certificates", subtitle: "Use a P12 and provisioning profile safely", introduction: "The signer needs a private key certificate and a profile that authorizes the target app and device.", symbol: "signature", color: .teal,
        steps: [
            .init(title: "Share both files", body: "In Files, select the .p12 and .mobileprovision files, tap Share, and choose Workspace. They are copied into Certificates and Provisioning Profiles."),
            .init(title: "Save the password", body: "Settings > Signing and JIT stores the certificate password in the device Keychain. Clear it when rotating certificates or sharing the device."),
            .init(title: "Check the profile", body: "The profile must contain the device UDID, a matching App ID/bundle identifier, valid dates, and entitlements accepted by the signing certificate."),
            .init(title: "Sign and install", body: "Installer can sign an imported IPA and request an iOS installation. If iOS reports that integrity cannot be verified, inspect profile, certificate, bundle ID, entitlements, and device trust."),
        ], destination: .settings, note: "Never commit a P12, password, provisioning profile, or GitHub token to a repository. A paid certificate still requires a matching profile and device authorization.")

    static let liveContainer = WorkspaceHelpTopic(
        id: "livecontainer", title: "LiveContainer and JIT", subtitle: "Run supported guests in the isolated workspace", introduction: "LiveContainer is the guest runtime used by Workspace. It is bundled under a separate Workspace bundle ID and does not replace a separate LiveContainer installation.", symbol: "shippingbox.and.arrow.backward.fill", color: .green,
        steps: [
            .init(title: "Prepare a guest", body: "Import an IPA through Installer and choose LiveContainer. Follow the preparation plan shown by the runtime if the guest needs setup."),
            .init(title: "Enable JIT", body: "Settings > LiveContainer or Signing and JIT shows the configured provider and diagnostics. Certificate and JITStreamer paths depend on device and iOS support."),
            .init(title: "Launch and manage", body: "Launch a guest from the Workspace home or Installed tab. Remove it from the home context menu when you no longer need it."),
            .init(title: "Use developer controls", body: "Inspector, logs, Frida, screenshots, and MCP controls are scoped to supported guests launched through this runtime and may require an instrumented guest."),
        ], destination: .settings, note: "JIT and background execution are limited by iOS policy and can expire. Workspace cannot grant entitlements that iOS has not authorized.")

    static let aiModels = WorkspaceHelpTopic(
        id: "ai-models", title: "AI models", subtitle: "Import weights and start a local chat", introduction: "The AI app includes the chat and model registry UI. Model weights are imported separately so you can choose what occupies device storage.", symbol: "brain.head.profile", color: .purple,
        steps: [
            .init(title: "Get a compatible model", body: "Download a model in a supported format such as GGUF, GGML, MLModel, MLPackage, ONNX, or Safetensors from a source you trust."),
            .init(title: "Share it to Workspace", body: "Because the system picker may not return large files reliably, use Files > Share > Workspace or drag the model into Workspace Files / AI Models."),
            .init(title: "Select it in AI", body: "Open AI, choose the discovered model, select an available inference backend, and wait for the first-load scan to finish."),
            .init(title: "Tune memory", body: "Start with a small context and conservative thread count. Export chats or logs from the AI app when you need to move them."),
        ], destination: .ai, note: "Qwen 3.5 4B, Phi-4 Mini, and Llama 3.2 3B are targets, not guarantees. Device RAM, quantization, backend support, heat, and speed determine whether a model runs. Weights are not embedded unless a package explicitly says so.")

    static let githubActions = WorkspaceHelpTopic(
        id: "github-actions", title: "GitHub Actions", subtitle: "Build device IPAs and simulator artifacts", introduction: "The repository workflow builds unsigned artifacts on GitHub's macOS/Xcode runner. Signing remains a separate, credential-sensitive step.", symbol: "arrow.triangle.branch", color: .indigo,
        steps: [
            .init(title: "Authenticate GitHub", body: "Use your existing gh login on the development computer. If pushing a workflow is rejected, the token needs workflow permission; do not paste that token into Workspace."),
            .init(title: "Push the project", body: "Commit the Xcode project, workflow, and modules.json, then push to main. The workflow also supports manual dispatch from Actions."),
            .init(title: "Watch the run", body: "Open Actions, select Build iOS 27 IPA, and inspect the job logs. Device and simulator builds are separate jobs."),
            .init(title: "Download artifacts", body: "When the run succeeds, download the unsigned IPA or simulator artifact. Sign a device IPA with authorized credentials before attempting installation."),
            .init(title: "Protect secrets", body: "For a private signing workflow, use GitHub encrypted secrets for the P12, password, and profile. Rotate them and avoid printing decoded files in logs."),
        ], destination: .devStudio, note: "A GitHub macOS runner is required for Xcode builds. The repository's default modules feed is empty until you publish package assets.")

    static let developerTools = WorkspaceHelpTopic(
        id: "developer-tools", title: "Developer tools and MCP", subtitle: "Inspector, logs, network, and sandbox tools", introduction: "Developer surfaces are grouped in the Developer app. MCP exposes authenticated workspace operations over the local network.", symbol: "wrench.and.screwdriver.fill", color: .blue,
        steps: [
            .init(title: "Start the server", body: "Open Developer > Network or MCP and start the local server. Grant Local Network permission when iOS asks."),
            .init(title: "Use the correct address", body: "127.0.0.1 means the iPhone itself. A computer or Raspberry Pi must connect to the phone's LAN IP, with the displayed port and token."),
            .init(title: "Limit access", body: "Use a strong token, keep the server on a trusted network, and stop it when finished. Treat screenshots, files, logs, and control endpoints as sensitive."),
            .init(title: "Inspect a guest", body: "Inspector and Frida features apply to supported apps launched through LiveContainer. They do not provide arbitrary control over system apps or unrelated processes."),
            .init(title: "Remote option", body: "A Pi or cloudflared tunnel can host builders or a bridge, but keep the existing tunnel isolated, authenticate every request, and revoke exposed tokens."),
        ], destination: .devStudio, note: "iOS may suspend background servers. Use a foreground session for long operations and design clients to reconnect after suspension.")

    static let networking = WorkspaceHelpTopic(
        id: "networking", title: "Network and remote services", subtitle: "Localhost, LAN, Pi, and tunnels", introduction: "Most connection errors come from using an address that belongs to a different device or from a stopped/suspended server.", symbol: "network", color: .green,
        steps: [
            .init(title: "Identify the host", body: "Use 127.0.0.1 only when the client and server are inside the same iPhone. Use the phone's LAN IP for a computer connecting to the phone, or the Pi's LAN IP for a server on the Pi."),
            .init(title: "Check reachability", body: "Confirm the service is running, the port is listening, Local Network permission is enabled, and the Wi-Fi network allows peer traffic."),
            .init(title: "Use HTTPS carefully", body: "For a remote tunnel, verify the hostname and certificate, keep upload tokens private, and shut down or rotate a tunnel that was shared publicly."),
            .init(title: "Expect suspension", body: "Background execution and the approximately short grace period after leaving an app are not guaranteed. Resume the app for long transfers."),
        ], destination: .devStudio, note: "A tunnel does not make an unprotected service safe. Authenticate and authorize every request.")

    static let troubleshooting = WorkspaceHelpTopic(
        id: "troubleshooting", title: "Troubleshooting", subtitle: "Fix the problems people hit most often", introduction: "Start with the matching symptom, retry once, and then use the diagnostic information shown by the relevant app.", symbol: "wrench.and.screwdriver.fill", color: .orange,
        steps: [
            .init(title: "Files picker does nothing", body: "Share the file to Workspace or drag it into Workspace Files, then select the internal copy. Check Certificates, Provisioning Profiles, IPAs, or AI Models."),
            .init(title: "App integrity cannot be verified", body: "Verify the profile's device and App ID, certificate/profile match, bundle identifier, dates, entitlements, and iOS trust. Re-sign the complete bundle and nested code."),
            .init(title: "GitHub feed fails", body: "Confirm an HTTPS raw GitHub URL, valid JSON, a supported module id, reachable asset, declared size under 2 GB, and matching SHA-256."),
            .init(title: "AI model is slow or crashes", body: "Use a smaller or more heavily quantized model, reduce context, close other apps, and check that the selected backend supports the format."),
            .init(title: "MCP cannot connect", body: "Use the server's current LAN address and port, not 127.0.0.1 from another device. Check token, firewall, Local Network permission, and whether iOS suspended the server."),
            .init(title: "JIT is unavailable", body: "Return to Settings, inspect provider diagnostics, re-share signing assets if needed, and remember that device/iOS support and background limits still apply."),
        ], destination: .settings, note: "If a reset is necessary, export files and diagnostics first. Reset workspace removes launcher state and may remove app-owned data.")

    static let privacy = WorkspaceHelpTopic(
        id: "privacy", title: "Privacy and safety", subtitle: "Protect certificates, files, and tokens", introduction: "Workspace can hold private signing material, source code, model weights, logs, and network credentials. Treat its storage as sensitive.", symbol: "lock.shield.fill", color: .red,
        steps: [
            .init(title: "Protect signing assets", body: "Keep P12 files and passwords private. Use Keychain storage for passwords, delete old profiles, and rotate a certificate if it was exposed."),
            .init(title: "Review module sources", body: "Only add GitHub repositories and packages you trust. The catalog verifies transport and an optional hash, but it cannot make an untrusted package safe."),
            .init(title: "Limit MCP", body: "Use least-privilege tokens and a trusted LAN. Stop the server and revoke tokens when you are finished."),
            .init(title: "Back up deliberately", body: "Back up source and model files you need. Do not back up or publish secrets with ordinary project archives."),
        ], destination: .fileManager, note: "Workspace is a sandboxed iOS app. It cannot bypass iOS security boundaries or grant third-party code system-wide access.")

    static let limits = WorkspaceHelpTopic(
        id: "limits", title: "Stock iOS limits", subtitle: "Set expectations before troubleshooting", introduction: "These are platform boundaries rather than missing buttons in Workspace.", symbol: "exclamationmark.triangle.fill", color: .orange,
        steps: [
            .init(title: "Downloaded native code", body: "Stock iOS cannot dynamically execute arbitrary unsigned Mach-O, compiler, runtime, or framework binaries downloaded into an app's sandbox."),
            .init(title: "Home Screen installation", body: "Only iOS controls final installation and trust. Workspace can prepare and request an install, but it cannot force iOS to accept an invalid profile or entitlement set."),
            .init(title: "JIT and background work", body: "JIT availability, background grace periods, and server lifetime depend on iOS version, device, entitlements, and current system policy."),
            .init(title: "Frida and MCP scope", body: "Inspection and control are limited to supported, opted-in LiveContainer guests. They do not control arbitrary system apps."),
            .init(title: "Heavy runtimes and AI", body: "LLVM, Java, .NET, Python, and model weights can require hundreds of megabytes or more. They must be imported, signed into the app, or run on a remote builder; they are not silently embedded."),
        ], destination: nil, note: "When a feature is unavailable, Help should explain the boundary and the supported alternative rather than promise a workaround.")
}
