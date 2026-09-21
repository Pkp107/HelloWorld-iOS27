#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
UPSTREAM_REPOSITORY="https://github.com/LiveContainer/LiveContainer.git"
UPSTREAM_REVISION="4dbe0f9"
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
cp "${ROOT_DIR}/WorkspaceModules.swift" "${SHELL_ROOT}/WorkspaceModules.swift"
cp "${ROOT_DIR}/DeveloperTools.swift" "${SHELL_ROOT}/DeveloperTools.swift"
cp "${ROOT_DIR}/WorkspaceMCPServer.swift" "${SHELL_ROOT}/WorkspaceMCPServer.swift"
cp "${ROOT_DIR}/WorkspaceAdvancedServices.swift" "${SHELL_ROOT}/WorkspaceAdvancedServices.swift"
cp "${ROOT_DIR}/LiveContainerRuntime.swift" "${SHELL_ROOT}/LiveContainerRuntime.swift"
cp "${ROOT_DIR}/NativeWorkspaceViews.swift" "${SHELL_ROOT}/NativeWorkspaceViews.swift"
cp "${ROOT_DIR}/NativeWorkspaceInstaller.swift" "${SHELL_ROOT}/NativeWorkspaceInstaller.swift"
cp "${ROOT_DIR}/SigningAssetStore.swift" "${SHELL_ROOT}/SigningAssetStore.swift"
cp "${ROOT_DIR}/LocalInstallServer.swift" "${SHELL_ROOT}/LocalInstallServer.swift"
cp "${ROOT_DIR}/WorkspaceShareExtension.swift" "${BUILD_ROOT}/ShareExtension/WorkspaceShareExtension.swift"
cp "${ROOT_DIR}/WorkspaceHomeScreenSigner.mm" "${BUILD_ROOT}/ZSign/WorkspaceHomeScreenSigner.mm"
cp "${ROOT_DIR}/WorkspaceLCSigningBridge.m" "${BUILD_ROOT}/LiveContainerSwiftUI/Utilities/WorkspaceLCSigningBridge.m"

# Retain the actual LiveContainer guest surface for the authenticated MCP
# bridge. The view is registered only while its scene is alive; control still
# requires the opted-in Frida Gadget inside that guest process.
MULTITASK_WINDOW="${BUILD_ROOT}/MultitaskSupport/MultitaskAppWindow.swift"
perl -0pi -e 's/func appSceneVCAppDidExit\(_: AppSceneViewController!\) \{\r?\n\s*onExit\(\)\r?\n\s*\}/func appSceneVCAppDidExit(_ vc: AppSceneViewController!) {\n            Task { \@MainActor in\n                WorkspaceGuestControlCenter.shared.unregisterGuestView(vc.contentView)\n            }\n            onExit()\n        }/g' "${MULTITASK_WINDOW}"
perl -0pi -e 's/(func appSceneVC\(_ vc: AppSceneViewController!, didInitializeWithError error: \(any Error\)!\) \{)/$1\n            Task { \@MainActor in\n                WorkspaceGuestControlCenter.shared.registerGuestView(vc.contentView, bundleIdentifier: vc.bundleId ?? "")\n            }/g' "${MULTITASK_WINDOW}"

# LCUtils dynamically loads ZSign and PKZipArchiver, avoiding a static link
# from the Workspace SwiftUI framework.
perl -0pi -e 's|(\@interface LCUtils : NSObject)|$1\n+ (void)workspaceSignAppAtPath:(NSString *)appPath bundleIdentifier:(NSString *)bundleIdentifier certificate:(NSData *)certificate password:(NSString *)password completionHandler:(void (^)(BOOL success, NSError *error))completionHandler;\n+ (void)workspaceSignHomeScreenAppAtPath:(NSString *)appPath bundleIdentifier:(NSString *)bundleIdentifier certificate:(NSData *)certificate provisioningProfile:(NSData *)provisioningProfile password:(NSString *)password completionHandler:(void (^)(BOOL success, NSError *error))completionHandler;\n+ (NSData *)workspaceZipDirectoryAtURL:(NSURL *)url;\n|' "${BUILD_ROOT}/LiveContainerSwiftUI/Utilities/LCUtils.h"
perl -0pi -e 's|\n\@end\s*\z|\n+ (void)workspaceSignAppAtPath:(NSString *)appPath bundleIdentifier:(NSString *)bundleIdentifier certificate:(NSData *)certificate password:(NSString *)password completionHandler:(void (^)(BOOL success, NSError *error))completionHandler {\n    NSError *error = nil;\n    [self loadStoreFrameworksWithError2:\&error];\n    if (error) { completionHandler(NO, error); return; }\n    NSProgress *progress = [NSClassFromString(\@"ZSigner\") signWithAppPath:appPath bundleId:bundleIdentifier cert:certificate pass:password completionHandler:completionHandler];\n    if (!progress) { completionHandler(NO, [NSError errorWithDomain:NSBundle.mainBundle.bundleIdentifier code:2 userInfo:nil]); }\n}\n\n+ (NSData *)workspaceZipDirectoryAtURL:(NSURL *)url {\n    return [[NSClassFromString(\@"PKZipArchiver\") new] zippedDataForURL:url];\n}\n\n\@end\n|' "${BUILD_ROOT}/LiveContainerSwiftUI/Utilities/LCUtils.m"

# Home Screen IPAs need profile-derived entitlements and a CMS signature. The
# JIT-only upstream entry point does not consume the selected profile, so the
# Workspace adapter uses the same ZSign Mach-O engine with full profile data.

# Let the native LiveContainer share service hand supported signing assets to
# the Workspace app-group inbox before the main app consumes them.
perl -0pi -e 's|ShareExtensionRootView\(viewModel: viewModel, extensionContext: extensionContext\)|WorkspaceShareRootView(viewModel: viewModel, extensionContext: extensionContext)|' "${BUILD_ROOT}/ShareExtension/ShareExtensionHandler.swift"
perl -0pi -e 's|UIHostingController<ShareExtensionRootView>|UIHostingController<AnyView>|; s|let root = WorkspaceShareRootView\(viewModel: viewModel, extensionContext: extensionContext\)|let root = AnyView(WorkspaceShareRootView(viewModel: viewModel, extensionContext: extensionContext))|' "${BUILD_ROOT}/ShareExtension/ShareExtensionHandler.swift"

# The upstream application remains the native runtime host; only its SwiftUI
# root is replaced with the Workspace shell.
cp "${ROOT_DIR}/NativeLCTabView.swift" "${BUILD_ROOT}/LiveContainerSwiftUI/Views/LCTabView.swift"

/usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName Workspace" "${BUILD_ROOT}/LiveContainer/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleName Workspace" "${BUILD_ROOT}/LiveContainer/Info.plist"
/usr/libexec/PlistBuddy -c "Add :NSLocalNetworkUsageDescription string Workspace uses the local network for IPA installation, development servers, and its authenticated workspace file bridge." "${BUILD_ROOT}/LiveContainer/Info.plist" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Add :NSAppTransportSecurity dict" "${BUILD_ROOT}/LiveContainer/Info.plist" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Add :NSAppTransportSecurity:NSAllowsLocalNetworking bool true" "${BUILD_ROOT}/LiveContainer/Info.plist" 2>/dev/null || true
# Keep this host distinct from an installed upstream LiveContainer.
sed -i '' 's/com\.kdt\.livecontainer$(DEVELOPMENT_TEAM_SUFFIX)/com.pkp107.workspace$(DEVELOPMENT_TEAM_SUFFIX)/' "${BUILD_ROOT}/xcconfigs/Global.xcconfig"

printf '%s\n' "${BUILD_ROOT}"
