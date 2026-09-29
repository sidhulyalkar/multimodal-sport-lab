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

echo "== MotionOS Apple bootstrap =="
echo "Repo:    $REPO_ROOT"
echo "Scheme:  $SCHEME"
echo "Packages:$SOURCE_PACKAGES"
echo

echo "-- Toolchain"
xcodebuild -version
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
