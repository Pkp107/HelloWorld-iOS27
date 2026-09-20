# Hello World for iOS 27

This is a minimal SwiftUI app with a single screen and a `Say hello` button. It uses system colors, Dynamic Type, safe-area-aware SwiftUI layout, and an accessible 44pt button target.

## Build the IPA with GitHub Actions

1. Create a GitHub repository and upload the contents of this folder.
2. Push to `main`, or open **Actions > Build iOS 27 IPA > Run workflow**.
3. Download the `HelloWorld-iOS27-unsigned-ipa` artifact.
4. Send the `.ipa` to the iPhone with LocalSend.
5. Import it into FlekStore and use FlekStore's supported signing/install flow.

The workflow intentionally creates an **unsigned** IPA. A normal iPhone will not install an unsigned app directly; FlekStore must sign it or use a compatible installation method. GitHub Actions only builds the package.

## About the iOS 27 target

The iOS version used to compile the app comes from the Xcode SDK installed on GitHub's `xcode-27` macOS runner. The workflow checks that `xcrun` reports an `iphoneos` SDK beginning with `27.` and fails with the available SDK list if it does not. The deployment target remains iOS 18 so the app can run on supported devices while being compiled with the iOS 27 SDK.
