#!/usr/bin/env bash
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/.." && pwd)"
PROJECT="$REPO_ROOT/apple/MotionOSHost/MotionOSHost.xcodeproj"

echo "== MotionOS Xcode agent preflight =="
echo "Repo: $REPO_ROOT"
echo

echo "-- Selected developer directory"
SELECTED="$(xcode-select -p 2>/dev/null || true)"
echo "${SELECTED:-unavailable}"

if [[ -z "$SELECTED" || "$SELECTED" == *"/CommandLineTools" ]]; then
  cat <<'EOF'

The shell is not using the full Xcode toolchain.
If Xcode is installed at /Applications/Xcode.app:

  sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer
  sudo xcodebuild -runFirstLaunch

Then rerun this script.
EOF
  exit 1
fi

echo
echo "-- Xcode"
xcodebuild -version

echo
echo "-- Swift"
xcrun swift --version

echo
echo "-- Xcode MCP bridge"
if MCPBRIDGE="$(xcrun --find mcpbridge 2>/dev/null)"; then
  echo "available: $MCPBRIDGE"
else
  cat <<'EOF'
missing: xcrun mcpbridge

The selected Xcode build does not expose the external-agent MCP bridge.
Check Xcode > Settings > Intelligence and confirm this is a current Xcode 27 build.
EOF
  exit 1
fi

echo
echo "-- Headless Xcode MCP preview"
if MCPSERVER="$(xcrun --find mcp-server 2>/dev/null)"; then
  echo "available: $MCPSERVER"
  cat <<'EOF'

This Xcode build contains the headless MCP preview.

To opt in:
  sudo xcrun mcp-server enable
  xcrun mcp-server status

Do not use --unsafe-always-allow-all-agents on a normal workstation.
EOF
else
  cat <<'EOF'
not present in this Xcode toolchain.

That is not a blocker. Use Apple's mcpbridge workflow:
  1. Open Xcode > Settings > Intelligence.
  2. Enable "Allow external agents to use Xcode tools".
  3. Open MotionOSHost.xcodeproj in Xcode.
  4. Register xcrun mcpbridge with your external agent.

Examples:
  codex mcp add xcode -- xcrun mcpbridge
  claude mcp add --transport stdio xcode -- xcrun mcpbridge

The standalone mcp-server command is an Xcode 27 preview and is not assumed
to exist by MotionOS.
EOF
fi

echo
echo "-- MotionOS Xcode project"
if [[ -d "$PROJECT" ]]; then
  echo "present: $PROJECT"
else
  echo "not generated yet"
  echo "generate with:"
  echo "  cd $REPO_ROOT/apple/MotionOSHost && bash bootstrap.sh --no-open"
fi

echo
echo "-- Useful verification"
echo "  xcrun --find mcpbridge"
echo "  xcodebuild -showsdks"
echo "  xcrun devicectl list devices"
echo
echo "Preflight complete."
