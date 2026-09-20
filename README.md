# Workspace for iOS 27

Workspace is a SwiftUI launcher compiled with the iOS 27 SDK. It includes a fixed, non-scrolling home surface, wallpaper selection, folders, a first-run setup flow, Installer, Installed Apps, Settings, IPA Signer, and the built-in Hello World app. LiveContainer runtime controls live inside Settings, while LiveContainer-installed apps appear on the Workspace home screen. Apps open as full-screen surfaces with an edge home bar: on the right in portrait and on the left in landscape. The bar can be tapped or swiped.

## Build the IPA with GitHub Actions

1. Push this repository to GitHub.
2. Push to `main`, or open **Actions > Build iOS 27 IPA > Run workflow**.
3. Download the `Workspace-iOS27-livecontainer-unsigned-ipa` artifact for the integrated runtime. The `HelloWorld-iOS27-unsigned-ipa` artifact remains the lightweight fallback target.
4. Send the `.ipa` to the iPhone with LocalSend.
5. Import it into FlekStore and use FlekStore's supported signing and install flow.

The workflow creates an **unsigned** IPA. GitHub Actions only builds the package; an iPhone still needs a compatible signing and installation method.

## LiveContainer status

The integrated artifact is assembled from pinned upstream LiveContainer sources, including the native bootstrap, shared framework, process and launch extensions, loader, ZSign, and required submodules. Its Installer and Installed Apps entries use the upstream importer and guest-app list. The fallback target keeps the same UI contracts and stores imported IPAs locally, but cannot execute guest processes on its own.

The IPA Signer app has its own IPA picker and copies the selected certificate and provisioning profile into protected, app-owned storage. Those signing assets can be imported during setup and are also reused for certificate-based JIT. A compatible certificate and provisioning profile are still required for signing.

Installer accepts local IPAs and stores custom HTTP/HTTPS repository URLs for AltStore, SideStore, eSign, or KSign-compatible feeds. The source detail screen opens a feed in Safari or Files; the native LiveContainer importer performs the actual guest installation in the integrated artifact.

LiveContainer is AGPLv3. If its source is integrated into this public repository, preserve the upstream license and corresponding source obligations.

## iOS 27 target

The workflow checks that the GitHub `xcode-27` runner exposes an `iphoneos` SDK beginning with `27.`. The deployment target remains iOS 18 so the build can run on supported devices while using the iOS 27 SDK. A second job compiles the app for an iOS 27 simulator and uploads the `.app` bundle.
