#!/usr/bin/env bash
set -euo pipefail

# Workspace uses its own port and process. This deliberately does not inspect,
# stop, or replace any existing cloudflared process serving another project.
: "${WORKSPACE_PUBLIC_BASE_URL:?Set the HTTPS Cloudflare URL for Workspace}"
: "${WORKSPACE_UPLOAD_TOKEN:?Set a private upload token}"
WORKSPACE_PORT="${WORKSPACE_PORT:-8072}"
WORKSPACE_STORAGE="${WORKSPACE_STORAGE:-$HOME/WorkspaceFiles}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if ps -eo args | grep -E '[p]ython3 .*workspace_pi_server.py' >/dev/null 2>&1; then
  echo "Workspace Pi server is already running; leaving it untouched."
  exit 0
fi

mkdir -p "$WORKSPACE_STORAGE"
exec env \
  WORKSPACE_PUBLIC_BASE_URL="$WORKSPACE_PUBLIC_BASE_URL" \
  WORKSPACE_UPLOAD_TOKEN="$WORKSPACE_UPLOAD_TOKEN" \
  WORKSPACE_PORT="$WORKSPACE_PORT" \
  WORKSPACE_STORAGE="$WORKSPACE_STORAGE" \
  python3 "$SCRIPT_DIR/workspace_pi_server.py"
