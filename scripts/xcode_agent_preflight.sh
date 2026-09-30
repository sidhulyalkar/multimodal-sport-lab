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

echo
echo "-- Discovered Xcode applications"
declare -a XCODE_APPS=()

add_xcode() {
  local app="$1"
  [[ -d "$app/Contents/Developer" ]] || return 0
  local existing
  for existing in "${XCODE_APPS[@]:-}"; do
    [[ "$existing" == "$app" ]] && return 0
  done
  XCODE_APPS+=("$app")
}

while IFS= read -r app; do
  [[ -n "$app" ]] && add_xcode "$app"
done < <(
  {
    find /Applications "$HOME/Applications" "$HOME/Downloads" -maxdepth 2 -name 'Xcode*.app' -type d -print 2>/dev/null || true
    mdfind "kMDItemCFBundleIdentifier == 'com.apple.dt.Xcode'" 2>/dev/null || true
  } | sort -u
)

if [[ "${#XCODE_APPS[@]}" -eq 0 ]]; then
  echo "none found"
else
  for app in "${XCODE_APPS[@]}"; do
    version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist" 2>/dev/null || echo unknown)"
    build="$(/usr/libexec/PlistBuddy -c 'Print :ProductBuildVersion' "$app/Contents/version.plist" 2>/dev/null || true)"
    if [[ -n "$build" ]]; then
      echo "$app -> Xcode $version ($build)"
    else
      echo "$app -> Xcode $version"
    fi
  done
fi

if [[ -z "$SELECTED" || "$SELECTED" == *"/CommandLineTools" ]]; then
  cat <<'EOF'

FAIL: the shell is not using the full Xcode toolchain.

Select the intended Xcode explicitly, for example:
  sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer
  sudo xcodebuild -runFirstLaunch

Then rerun this script.
EOF
  exit 1
fi

echo
echo "-- Active Xcode"
XCODE_VERSION_OUTPUT="$(xcodebuild -version)"
echo "$XCODE_VERSION_OUTPUT"
XCODE_VERSION="$(awk 'NR == 1 { print $2 }' <<<"$XCODE_VERSION_OUTPUT")"
XCODE_MAJOR="${XCODE_VERSION%%.*}"

echo
echo "-- Swift"
xcrun swift --version

if [[ ! "$XCODE_MAJOR" =~ ^[0-9]+$ ]]; then
  echo "FAIL: unable to parse active Xcode version: $XCODE_VERSION" >&2
  exit 1
fi

if (( XCODE_MAJOR < 27 )); then
  cat <<EOF

FAIL: Xcode $XCODE_VERSION is selected.

MotionOS package resolution needs Xcode 16.3+, and the Xcode external-agent
tools used by this workflow require the Xcode 27 family. On macOS 27.2, use
a current Xcode 27.2 build.

If a newer Xcode appears in the discovered list above, select it with:
  sudo xcode-select --switch "/path/to/Xcode.app/Contents/Developer"
  sudo xcodebuild -runFirstLaunch

Then rerun this script.
EOF
  exit 1
fi

echo
echo "-- SDKs"
echo "iOS:     $(xcrun --sdk iphoneos --show-sdk-version)"
echo "watchOS: $(xcrun --sdk watchos --show-sdk-version)"
echo "macOS:   $(xcrun --sdk macosx --show-sdk-version)"

echo
echo "-- Xcode MCP bridge"
if MCPBRIDGE="$(xcrun --find mcpbridge 2>/dev/null)"; then
  echo "available: $MCPBRIDGE"
else
  cat <<'EOF'
missing: xcrun mcpbridge

The selected Xcode 27 build does not expose the documented external-agent MCP
bridge. Check Xcode > Settings > Intelligence, run first-launch setup, and
verify that this is a full current Xcode installation.
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

That is not a blocker. Use Apple's documented mcpbridge workflow:
  1. Open Xcode > Settings > Intelligence.
  2. Enable "Allow external agents to use Xcode tools".
  3. Open MotionOSHost.xcodeproj in Xcode.
  4. Register xcrun mcpbridge with your external agent.

Examples:
  codex mcp add xcode -- xcrun mcpbridge
  claude mcp add --transport stdio xcode -- xcrun mcpbridge
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
echo "  xcrun --find mcp-server"
echo "  xcodebuild -showsdks"
echo "  xcrun devicectl list devices"
echo
echo "Preflight complete."
