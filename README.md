# Workspace for iOS 27

Workspace is a SwiftUI launcher compiled with the iOS 27 SDK. It includes a fixed, non-scrolling home surface, wallpaper selection, folders, a first-run setup flow, Installer, Installed Apps, Settings, IPA Signer, and the built-in Hello World app. LiveContainer runtime controls live inside Settings, while LiveContainer-installed apps appear on the Workspace home screen. Apps open as full-screen surfaces with an edge home bar: on the right in portrait and on the left in landscape. The bar can be tapped or swiped.

## Developer workspace

Workspace now includes four developer launcher apps:

- **Dev Studio** creates and edits Swift, C, C++, Java, C#, Python, TypeScript, and WASI starter projects in `Workspace Files/Projects`.
- **GitHub** stores a repository token in the device Keychain, selects repositories and branches, uploads the active source file through the GitHub Contents API, triggers Actions, and shows recent workflow runs.
- **Inspector** stores host diagnostics and creates a Frida Gadget preparation plan for guest IPAs managed by LiveContainer. A Gadget binary and re-signing are still required before a guest can be instrumented.
- **Network** runs an authenticated local HTTP/MCP bridge. It is restricted to `Workspace Files` and exposes `list_files`, `read_file`, `copy_file`, `move_file`, `delete_file`, and `make_directory`; it has no shell or access to other iOS sandboxes.
- **Remote Desktop** detects a Moonlight IPA installed through LiveContainer and launches it from a stable workspace entry.

Settings > **Modules** controls the optional language, build, debugging, network, and AI-runtime modules so large toolchains and model files can be managed separately.

### Build projects from Dev Studio

The default GitHub workflow is `.github/workflows/workspace-build.yml`. In Dev Studio's **Build** tab, enter a GitHub token with repository workflow and contents access, choose `owner/repository`, the branch, and `workspace-build.yml`.

The workflow supports these outputs:

- **Windows EXE:** C, C++, C#, Python, Java, or JavaScript.
- **WebAssembly:** C and C++.
- **iOS Simulator:** any project that provides an Xcode project and scheme.
- **iPhone IPA:** any project that provides an Xcode project and scheme. It produces an unsigned IPA by default; device installation still requires compatible signing assets.

Dev Studio uploads its source file under `WorkspaceProjects/<id>/Sources/` before dispatching a build. For iOS targets, add `xcode_project=path/App.xcodeproj` and `xcode_scheme=App` in the optional workflow-input editor. A real iOS app still needs a valid Xcode project, Apple SDK, and signing flow.

## Build the IPA with GitHub Actions

1. Push this repository to GitHub.
2. Push to `main`, or open **Actions > Build iOS 27 IPA > Run workflow**.
3. Download the `Workspace-iOS27-livecontainer-unsigned-ipa` artifact for the integrated runtime. The `HelloWorld-iOS27-unsigned-ipa` artifact remains the lightweight fallback target.
4. Send the `.ipa` to the iPhone with LocalSend.
5. Import it into FlekStore and use FlekStore's supported signing and install flow.

The workflow creates an **unsigned** IPA. GitHub Actions only builds the package; an iPhone still needs a compatible signing and installation method.

The on-device installer uses `UIApplication.beginBackgroundTask(withName:expirationHandler:)` while Workspace is foregrounded. UIKit may grant a short grace period, commonly around 30 seconds, after the app backgrounds; `UIApplication.backgroundTimeRemaining` is shown in the installer and the expiration handler stops advertising the local transfer. There is no general background-server entitlement that extends this period. `BGTaskScheduler` is for deferred refresh or processing and cannot keep an OTA socket alive during an interactive install.

## LiveContainer status

The integrated artifact is assembled from pinned upstream LiveContainer sources, including the native bootstrap, shared framework, process and launch extensions, loader, ZSign, and required submodules. Its Installer and Installed Apps entries use the upstream importer and guest-app list. The fallback target keeps the same UI contracts and stores imported IPAs locally, but cannot execute guest processes on its own.

The IPA Signer app has its own IPA picker and copies the selected certificate and provisioning profile into protected, app-owned storage. Those signing assets can be imported during setup and are also reused for certificate-based JIT. A compatible certificate and provisioning profile are still required for signing.

## Private Pi HTTPS handoff

Workspace can upload a signed IPA to a private Raspberry Pi host and open the returned HTTPS OTA manifest. The reference host listens on port `8072`; keep any other project on its existing port and tunnel. Copy `scripts/workspace_pi_server.py` and `scripts/start-workspace-pi.sh` to the Pi, then start the service with `WORKSPACE_PUBLIC_BASE_URL` set to the dedicated Cloudflare URL and `WORKSPACE_UPLOAD_TOKEN` set to a randomly generated secret. Start a separate `cloudflared tunnel --url http://127.0.0.1:8072` process for that service. Enter the same HTTPS URL and token in Installer's Workspace Pi handoff screen. The token is stored only in the app's local preferences and is not committed to this repository.

Installer accepts local IPAs and stores custom HTTP/HTTPS repository URLs for AltStore, SideStore, eSign, or KSign-compatible feeds. The source detail screen opens a feed in Safari or Files; the native LiveContainer importer performs the actual guest installation in the integrated artifact.

LiveContainer is AGPLv3. If its source is integrated into this public repository, preserve the upstream license and corresponding source obligations.

## iOS 27 target

The workflow checks that the GitHub `xcode-27` runner exposes an `iphoneos` SDK beginning with `27.`. The deployment target remains iOS 18 so the build can run on supported devices while using the iOS 27 SDK. A second job compiles the app for an iOS 27 simulator and uploads the `.app` bundle.
