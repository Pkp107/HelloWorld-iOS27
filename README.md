# Hello World for iOS 27

HelloOS is a SwiftUI workspace shell for iOS 27. It has a home screen, dock, folders, searchable app library, task-switcher-style sessions, settings, IPA import/storage, editable app metadata, and a built-in Hello World app. It uses system colors, Dynamic Type, safe-area-aware layout, and accessible 44pt controls.

## Build the IPA with GitHub Actions

1. Create a GitHub repository and upload the contents of this folder.
2. Push to `main`, or open **Actions > Build iOS 27 IPA > Run workflow**.
3. Download the `HelloWorld-iOS27-unsigned-ipa` artifact.
4. Send the `.ipa` to the iPhone with LocalSend.
5. Import it into FlekStore and use FlekStore's supported signing/install flow.

The workflow intentionally creates an **unsigned** IPA. A normal iPhone will not install an unsigned app directly; FlekStore must sign it or use a compatible installation method. GitHub Actions only builds the package.

## LiveContainer runtime status

The current HelloOS target manages imported IPAs and represents them in the workspace and task switcher. It does not execute guest IPAs yet. LiveContainer's execution layer is a native multi-target architecture that includes a bootstrap executable, `LiveContainerShared.framework`, loader and process extensions, Mach-O patching, dyld hooks, app-group entitlements, and device-specific signing/JIT paths. Those targets must be integrated as a separate native milestone; a SwiftUI screen alone cannot provide that runtime.

The upstream LiveContainer project is AGPLv3. This repository does not currently copy its source. If its code is integrated or the repository is distributed with a modified combined runtime, retain the upstream license and source obligations.

## About the iOS 27 target

The iOS version used to compile the app comes from the Xcode SDK installed on GitHub's `xcode-27` macOS runner. The workflow checks that `xcrun` reports an `iphoneos` SDK beginning with `27.` and fails with the available SDK list if it does not. The deployment target remains iOS 18 so the app can run on supported devices while being compiled with the iOS 27 SDK.

The simulator-build job compiles the app for `iphonesimulator` and uploads the resulting `.app` bundle. GitHub's Xcode 27 preview runner does not currently boot its simulator runtime reliably, so live launch and screenshot testing needs a Mac/Xcode session.
