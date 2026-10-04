#!/usr/bin/env bash
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
PROJECT="$HERE/MotionOSHost.xcodeproj"
CAPTURE_PACKAGE="$REPO_ROOT/apple/MotionOSAppleCapture"
SOURCE_PACKAGES="$REPO_ROOT/.build/apple-source-packages"
SCHEME="${MOTIONOS_SCHEME:-MotionOS-iOS}"
RESET=0
OPEN_PROJECT=1

usage() {
  cat <<'EOF'
Usage: bash bootstrap.sh [--reset-packages] [--no-open]

Generates the MotionOS Xcode project, validates the local Swift package,
and resolves all Swift Package Manager dependencies into a repo-local cache.

Options:
  --reset-packages  Remove only generated MotionOS Xcode/package state before resolving.
  --no-open         Do not open Xcode after a successful bootstrap.
  -h, --help        Show this help.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --reset-packages)
      RESET=1
      shift
      ;;
    --no-open)
      OPEN_PROJECT=0
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

require() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 1
  fi
}

require xcodegen
require xcodebuild
require swift

# Xcode's GUI can be installed while xcode-select still points at the smaller
# CommandLineTools bundle. In that state, xcodebuild exists but refuses to run.
# Prefer an explicit MotionOS override, otherwise use the selected developer
# directory, and finally fall back to the standard Xcode.app installation for
# this script only. We intentionally do not mutate the user's global
# xcode-select configuration.
SELECTED_DEVELOPER_DIR="$(xcode-select -p 2>/dev/null || true)"
if [[ -n "${MOTIONOS_DEVELOPER_DIR:-}" ]]; then
  export DEVELOPER_DIR="$MOTIONOS_DEVELOPER_DIR"
elif [[ "$SELECTED_DEVELOPER_DIR" == *"/CommandLineTools" ]] \
  && [[ -d "/Applications/Xcode.app/Contents/Developer" ]]; then
  export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
elif [[ -n "$SELECTED_DEVELOPER_DIR" ]]; then
  export DEVELOPER_DIR="$SELECTED_DEVELOPER_DIR"
fi

echo "== MotionOS Apple bootstrap =="
echo "Repo:    $REPO_ROOT"
echo "Scheme:  $SCHEME"
echo "Packages:$SOURCE_PACKAGES"
echo

echo "-- Toolchain"
echo "xcode-select: ${SELECTED_DEVELOPER_DIR:-unavailable}"
echo "DEVELOPER_DIR: ${DEVELOPER_DIR:-not set}"
if ! xcodebuild -version; then
  cat >&2 <<'EOF'

MotionOS requires the full Xcode developer toolchain.

If Xcode is installed in /Applications/Xcode.app, either:
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
  bash bootstrap.sh --reset-packages

or switch the system-wide selection once:
  sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer

If Xcode lives somewhere else, set:
  export MOTIONOS_DEVELOPER_DIR="/path/to/Xcode.app/Contents/Developer"
EOF
  exit 1
fi
XCODE_VERSION="$(xcodebuild -version | awk 'NR == 1 { print $2 }')"
XCODE_MAJOR="${XCODE_VERSION%%.*}"
XCODE_REMAINDER="${XCODE_VERSION#*.}"
XCODE_MINOR="${XCODE_REMAINDER%%.*}"

if [[ ! "$XCODE_MAJOR" =~ ^[0-9]+$ ]] || [[ ! "$XCODE_MINOR" =~ ^[0-9]+$ ]]; then
  echo "Unable to parse Xcode version: $XCODE_VERSION" >&2
  exit 1
fi

# The lean product build uses the local Swift 6 MotionOS package and does not
# resolve the optional MetaWear / NordicDFU graph. Xcode 16+ is sufficient for
# compile-only work; current physical iOS/watchOS 26 qualification should use
# Xcode 26 or newer.
if (( XCODE_MAJOR < 16 )); then
  cat >&2 <<EOF

MotionOS requires Xcode 16 or newer.
Detected: Xcode $XCODE_VERSION

For current physical MotionOS qualification on iOS/watchOS 26 devices,
install Xcode 26 or newer.

After installing a newer Xcode:
  export MOTIONOS_DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
  bash bootstrap.sh --reset-packages
EOF
  exit 1
fi

if (( XCODE_MAJOR < 26 )); then
  cat >&2 <<EOF

WARNING: Xcode $XCODE_VERSION can resolve the current package graph, but
MotionOS physical qualification on current iOS/watchOS 26 hardware should use
Xcode 26 or newer. Continue only for simulator/compile-only work.
EOF
fi

xcodegen --version
swift --version
echo

if [[ "$RESET" -eq 1 ]]; then
  echo "-- Resetting generated project/package cache"
  rm -rf "$PROJECT"
  rm -rf "$SOURCE_PACKAGES"
fi

mkdir -p "$SOURCE_PACKAGES"

echo "-- Validating local MotionOSAppleCapture package"
swift package --package-path "$CAPTURE_PACKAGE" describe >/dev/null

echo "-- Generating Xcode project"
(
  cd "$HERE"
  xcodegen generate
)

echo "-- Resolving Swift package dependencies"
if ! xcodebuild \
  -resolvePackageDependencies \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -clonedSourcePackagesDirPath "$SOURCE_PACKAGES"
then
  cat >&2 <<'EOF'

MotionOS package resolution failed.

The generated project is intact. Re-run with:
  bash bootstrap.sh --reset-packages

If it still fails, copy the FIRST SwiftPM/Xcode resolver error above.
Do not fix "Missing package product" by manually deleting target dependencies;
that message is usually downstream of the resolver failure.
EOF
  exit 1
fi

echo "-- Verifying generated Watch app metadata"
WATCH_INFO="$HERE/Watch/Info.plist"
if [[ ! -f "$WATCH_INFO" ]]; then
  echo "Generated Watch Info.plist is missing: $WATCH_INFO" >&2
  exit 1
fi
if [[ "$(/usr/libexec/PlistBuddy -c 'Print :WKApplication' "$WATCH_INFO" 2>/dev/null || true)" != "true" ]]; then
  echo "Generated Watch app must declare WKApplication=true for the single-target watchOS app." >&2
  exit 1
fi

echo "-- Verifying generated schemes"
xcodebuild -list -project "$PROJECT"

cat <<'EOF'

Bootstrap complete.

Next:
  1. Open MotionOSHost.xcodeproj.
  2. Select MotionOS-iOS + your physical iPhone.
  3. Set the same Development Team on MotionOSiOS and MotionOSWatch.
  4. Keep Clinical Health Records OFF.
  5. Build/run with Cmd-R.

The default project intentionally enables base HealthKit only. P0 uses an
active workout session; HealthKit Clinical Health Records are not part of the
MotionOS capture contract.
EOF

if [[ "$OPEN_PROJECT" -eq 1 ]]; then
  open "$PROJECT"
fi
