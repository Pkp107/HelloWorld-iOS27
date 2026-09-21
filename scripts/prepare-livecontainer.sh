#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
UPSTREAM_REPOSITORY="https://github.com/LiveContainer/LiveContainer.git"
UPSTREAM_REVISION="4dbe0f9"
FULL_ZSIGN_REPOSITORY="https://github.com/khcrysalis/Zsign-Package.git"
FULL_ZSIGN_REVISION="6ffe703df73ef9069adacdbb19d571f11a69a801"
BUILD_ROOT="${RUNNER_TEMP:-${ROOT_DIR}/.build}/WorkspaceLiveContainer"

rm -rf "${BUILD_ROOT}"
mkdir -p "$(dirname "${BUILD_ROOT}")"

# LiveContainer is AGPLv3. The build uses the pinned upstream source directly
# so the native bootstrap, extensions, ZSign, and submodules stay in sync.
git clone --recurse-submodules "${UPSTREAM_REPOSITORY}" "${BUILD_ROOT}" >&2
git -C "${BUILD_ROOT}" checkout --detach "${UPSTREAM_REVISION}" >&2
git -C "${BUILD_ROOT}" submodule update --init --recursive >&2

SHELL_ROOT="${BUILD_ROOT}/LiveContainerSwiftUI/WorkspaceShell"
mkdir -p "${SHELL_ROOT}"
cp "${ROOT_DIR}/ContentView.swift" "${SHELL_ROOT}/ContentView.swift"
cp "${ROOT_DIR}/VirtualOS.swift" "${SHELL_ROOT}/VirtualOS.swift"
cp "${ROOT_DIR}/WorkspaceViews.swift" "${SHELL_ROOT}/WorkspaceViews.swift"
cp "${ROOT_DIR}/LiveContainerRuntime.swift" "${SHELL_ROOT}/LiveContainerRuntime.swift"
cp "${ROOT_DIR}/NativeWorkspaceViews.swift" "${SHELL_ROOT}/NativeWorkspaceViews.swift"
cp "${ROOT_DIR}/NativeWorkspaceInstaller.swift" "${SHELL_ROOT}/NativeWorkspaceInstaller.swift"
cp "${ROOT_DIR}/SigningAssetStore.swift" "${SHELL_ROOT}/SigningAssetStore.swift"
cp "${ROOT_DIR}/LocalInstallServer.swift" "${SHELL_ROOT}/LocalInstallServer.swift"
cp "${ROOT_DIR}/WorkspaceShareExtension.swift" "${BUILD_ROOT}/ShareExtension/WorkspaceShareExtension.swift"

# LCUtils dynamically loads ZSign and PKZipArchiver, avoiding a static link
# from the Workspace SwiftUI framework.
perl -0pi -e 's|(\@interface LCUtils : NSObject)|$1\n+ (void)workspaceSignAppAtPath:(NSString *)appPath bundleIdentifier:(NSString *)bundleIdentifier certificate:(NSData *)certificate password:(NSString *)password completionHandler:(void (^)(BOOL success, NSError *error))completionHandler;\n+ (NSData *)workspaceZipDirectoryAtURL:(NSURL *)url;\n|' "${BUILD_ROOT}/LiveContainerSwiftUI/Utilities/LCUtils.h"
perl -0pi -e 's|\n\@end\s*\z|\n+ (void)workspaceSignAppAtPath:(NSString *)appPath bundleIdentifier:(NSString *)bundleIdentifier certificate:(NSData *)certificate password:(NSString *)password completionHandler:(void (^)(BOOL success, NSError *error))completionHandler {\n    NSError *error = nil;\n    [self loadStoreFrameworksWithError2:\&error];\n    if (error) { completionHandler(NO, error); return; }\n    NSProgress *progress = [NSClassFromString(\@"ZSigner\") signWithAppPath:appPath bundleId:bundleIdentifier cert:certificate pass:password completionHandler:completionHandler];\n    if (!progress) { completionHandler(NO, [NSError errorWithDomain:NSBundle.mainBundle.bundleIdentifier code:2 userInfo:nil]); }\n}\n\n+ (NSData *)workspaceZipDirectoryAtURL:(NSURL *)url {\n    return [[NSClassFromString(\@"PKZipArchiver\") new] zippedDataForURL:url];\n}\n\n\@end\n|' "${BUILD_ROOT}/LiveContainerSwiftUI/Utilities/LCUtils.m"

# Home Screen IPAs need profile-derived entitlements, nested-bundle signing,
# regenerated CodeResources, and a CMS signature. The JIT-only upstream entry
# point does none of those. This pinned MIT ZSign implementation supplies the
# standard bundle engine while retaining LiveContainer's runtime host.
git clone --depth 1 "${FULL_ZSIGN_REPOSITORY}" "${BUILD_ROOT}/WorkspaceZsign" >&2
git -C "${BUILD_ROOT}/WorkspaceZsign" fetch --depth 1 origin "${FULL_ZSIGN_REVISION}" >&2
git -C "${BUILD_ROOT}/WorkspaceZsign" checkout --detach "${FULL_ZSIGN_REVISION}" >&2
cp "${BUILD_ROOT}/WorkspaceZsign/src/bundle.cpp" "${BUILD_ROOT}/ZSign/bundle.cpp"
cp "${BUILD_ROOT}/WorkspaceZsign/src/bundle.h" "${BUILD_ROOT}/ZSign/bundle.h"
sed -i '' 's/#include "zsign\.hpp"/#include "zsign.hpp"\n#include "bundle.h"/' "${BUILD_ROOT}/ZSign/zsign.mm"
perl -0pi -e 's|(\@interface LCUtils : NSObject)|$1\n+ (void)workspaceSignHomeScreenAppAtPath:(NSString *)appPath bundleIdentifier:(NSString *)bundleIdentifier certificate:(NSData *)certificate provisioningProfile:(NSData *)provisioningProfile password:(NSString *)password completionHandler:(void (^)(BOOL success, NSError *error))completionHandler;\n|' "${BUILD_ROOT}/LiveContainerSwiftUI/Utilities/LCUtils.h"
perl -0pi -e 's|\n\@end\s*\z|\n+ (void)workspaceSignHomeScreenAppAtPath:(NSString *)appPath bundleIdentifier:(NSString *)bundleIdentifier certificate:(NSData *)certificate provisioningProfile:(NSData *)provisioningProfile password:(NSString *)password completionHandler:(void (^)(BOOL success, NSError *error))completionHandler {\n    NSError *error = nil;\n    [self loadStoreFrameworksWithError2:\&error];\n    if (error) { completionHandler(NO, error); return; }\n    NSProgress *progress = [NSClassFromString(\@"ZSigner\") workspaceSignHomeScreenAppAtPath:appPath bundleId:bundleIdentifier cert:certificate provision:provisioningProfile pass:password completionHandler:completionHandler];\n    if (!progress) { completionHandler(NO, [NSError errorWithDomain:NSBundle.mainBundle.bundleIdentifier code:2 userInfo:nil]); }\n}\n\n\@end\n|' "${BUILD_ROOT}/LiveContainerSwiftUI/Utilities/LCUtils.m"
perl -0pi -e 's|\n\@end\s*\z|\n+ (NSProgress*)workspaceSignHomeScreenAppAtPath:(NSString *)appPath bundleId:(NSString *)bundleId cert:(NSData *)key provision:(NSData *)provision pass:(NSString *)pass completionHandler:(void (^)(BOOL success, NSError *error))completionHandler;\n\@end\n|' "${BUILD_ROOT}/ZSign/zsigner.h"
perl -0pi -e 's|\n\@end\s*\z|\n+ (NSProgress*)workspaceSignHomeScreenAppAtPath:(NSString *)appPath bundleId:(NSString *)bundleId cert:(NSData *)key provision:(NSData *)provision pass:(NSString *)pass completionHandler:(void (^)(BOOL success, NSError *error))completionHandler {\n    NSProgress *progress = [NSProgress progressWithTotalUnitCount:1];\n    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{\n        NSString *root = NSTemporaryDirectory();\n        NSString *p12Path = [root stringByAppendingPathComponent:[[NSUUID UUID] UUIDString]];\n        NSString *profilePath = [root stringByAppendingPathComponent:[[NSUUID UUID] UUIDString]];\n        BOOL wroteP12 = [key writeToFile:p12Path options:NSDataWritingAtomic error:nil];\n        BOOL wroteProfile = [provision writeToFile:profilePath options:NSDataWritingAtomic error:nil];\n        ZSignAsset asset;\n        BOOL initialized = wroteP12 && wroteProfile && asset.Init("", string(p12Path.UTF8String), string(profilePath.UTF8String), "", string(pass.UTF8String), false, false, false);\n        ZBundle bundle;\n        BOOL signedApp = initialized && bundle.SignFolder(\&asset, string(appPath.UTF8String), string(bundleId.UTF8String), "", "", vector<string>(), true, false, false, true);\n        [[NSFileManager defaultManager] removeItemAtPath:p12Path error:nil];\n        [[NSFileManager defaultManager] removeItemAtPath:profilePath error:nil];\n        progress.completedUnitCount = 1;\n        dispatch_async(dispatch_get_main_queue(), ^{\n            if (signedApp) { completionHandler(YES, nil); }\n            else { NSString *message = initialized ? [NSString stringWithUTF8String:bundle.signFailedFiles.c_str()] : \@"The certificate does not match this provisioning profile or its password is incorrect."; completionHandler(NO, [NSError errorWithDomain:\@"WorkspaceSigner" code:1 userInfo:@{ NSLocalizedDescriptionKey: message.length ? message : \@"The IPA could not be signed." }]); }\n        });\n    });\n    return progress;\n}\n\n\@end\n|' "${BUILD_ROOT}/ZSign/zsign.mm"

# Let the native LiveContainer share service hand supported signing assets to
# the Workspace app-group inbox before the main app consumes them.
perl -0pi -e 's|ShareExtensionRootView\(viewModel: viewModel, extensionContext: extensionContext\)|WorkspaceShareRootView(viewModel: viewModel, extensionContext: extensionContext)|' "${BUILD_ROOT}/ShareExtension/ShareExtensionHandler.swift"
perl -0pi -e 's|UIHostingController<ShareExtensionRootView>|UIHostingController<AnyView>|; s|let root = WorkspaceShareRootView\(viewModel: viewModel, extensionContext: extensionContext\)|let root = AnyView(WorkspaceShareRootView(viewModel: viewModel, extensionContext: extensionContext))|' "${BUILD_ROOT}/ShareExtension/ShareExtensionHandler.swift"

# The upstream application remains the native runtime host; only its SwiftUI
# root is replaced with the Workspace shell.
cp "${ROOT_DIR}/NativeLCTabView.swift" "${BUILD_ROOT}/LiveContainerSwiftUI/Views/LCTabView.swift"

/usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName Workspace" "${BUILD_ROOT}/LiveContainer/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleName Workspace" "${BUILD_ROOT}/LiveContainer/Info.plist"
/usr/libexec/PlistBuddy -c "Add :NSLocalNetworkUsageDescription string Workspace hosts signed IPA installers locally on this device." "${BUILD_ROOT}/LiveContainer/Info.plist" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Add :NSAppTransportSecurity dict" "${BUILD_ROOT}/LiveContainer/Info.plist" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Add :NSAppTransportSecurity:NSAllowsLocalNetworking bool true" "${BUILD_ROOT}/LiveContainer/Info.plist" 2>/dev/null || true
# Keep this host distinct from an installed upstream LiveContainer.
sed -i '' 's/com\.kdt\.livecontainer$(DEVELOPMENT_TEAM_SUFFIX)/com.pkp107.workspace$(DEVELOPMENT_TEAM_SUFFIX)/' "${BUILD_ROOT}/xcconfigs/Global.xcconfig"

printf '%s\n' "${BUILD_ROOT}"
