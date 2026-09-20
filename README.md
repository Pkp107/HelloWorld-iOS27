# Workspace for iOS 27

Workspace is a SwiftUI home screen compiled with the iOS 27 SDK. It includes a dock, folders, separate built-in App Library, Settings, and IPA Signer apps, IPA import and metadata management, and a built-in Hello World app. Apps open as full-screen surfaces with an edge home bar: on the right in portrait and on the left in landscape. The bar can be tapped or swiped.

## Build the IPA with GitHub Actions

1. Push this repository to GitHub.
2. Push to `main`, or open **Actions > Build iOS 27 IPA > Run workflow**.
3. Download the `HelloWorld-iOS27-unsigned-ipa` artifact.
4. Send the `.ipa` to the iPhone with LocalSend.
5. Import it into FlekStore and use FlekStore's supported signing and install flow.

The workflow creates an **unsigned** IPA. GitHub Actions only builds the package; an iPhone still needs a compatible signing and installation method.

## LiveContainer status

The app now has a `LiveContainerRuntimeBridge` boundary and reports the stored IPA, signing state, and native framework availability in the UI. The current target does not claim to execute imported IPAs. Upstream LiveContainer execution is a native multi-target system that includes a bootstrap executable, `LiveContainerShared.framework`, loader and process extensions, Mach-O patching, dyld hooks, app-group entitlements, and device-specific signing or JIT paths. Those targets are not vendored into this small SwiftUI target, so imported IPAs remain managed files until that native adapter is linked.

The IPA Signer app provides the certificate and provisioning-profile workflow and validates that an imported IPA is present. It intentionally reports that export needs a native ZSign backend; selecting assets in the UI does not falsely produce a signed IPA.

LiveContainer is AGPLv3. If its source is integrated into this public repository, preserve the upstream license and corresponding source obligations.

## iOS 27 target

The workflow checks that the GitHub `xcode-27` runner exposes an `iphoneos` SDK beginning with `27.`. The deployment target remains iOS 18 so the build can run on supported devices while using the iOS 27 SDK. A second job compiles the app for an iOS 27 simulator and uploads the `.app` bundle.
