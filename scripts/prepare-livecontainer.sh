#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
UPSTREAM_REPOSITORY="https://github.com/LiveContainer/LiveContainer.git"
UPSTREAM_REVISION="4dbe0f9"
BUILD_ROOT="${RUNNER_TEMP:-${ROOT_DIR}/.build}/WorkspaceLiveContainer"
WORKSPACE_BUNDLE_IDENTIFIER="com.pkp107.workspace"

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
cp "${ROOT_DIR}/SigningAssetStore.swift" "${SHELL_ROOT}/SigningAssetStore.swift"

# Make ZSign's public Objective-C interface visible to the workspace shell so
# IPA Signer can sign an IPA selected directly from Files.
perl -0pi -e 's|(#include "Utilities/LCUtils\\.h")|$1\n#include "../ZSign/zsigner.h"|' "${BUILD_ROOT}/LiveContainerSwiftUI/LiveContainerSwiftUI-Bridging-Header.h"

# The upstream application remains the native runtime host; only its SwiftUI
# root is replaced with the workspace shell. All native launch code remains.
cp "${ROOT_DIR}/NativeLCTabView.swift" "${BUILD_ROOT}/LiveContainerSwiftUI/Views/LCTabView.swift"

/usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName Workspace" "${BUILD_ROOT}/LiveContainer/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleName Workspace" "${BUILD_ROOT}/LiveContainer/Info.plist"
# Give this host and all of its derived extensions an identity distinct from
# an installed upstream LiveContainer. The extension identifiers remain
# derived from the host identifier by the upstream xcconfig files.
sed -i '' 's/com\.kdt\.livecontainer$(DEVELOPMENT_TEAM_SUFFIX)/com.pkp107.workspace$(DEVELOPMENT_TEAM_SUFFIX)/' "${BUILD_ROOT}/xcconfigs/Global.xcconfig"

printf '%s\n' "${BUILD_ROOT}"
