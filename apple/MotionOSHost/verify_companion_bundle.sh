#!/usr/bin/env bash
set -euo pipefail

IPHONE_APP="${1:-}"

if [[ -z "$IPHONE_APP" ]]; then
  cat >&2 <<'EOF'
Usage:
  bash verify_companion_bundle.sh /path/to/MotionOS.app

The path must be the built iPhone app bundle. The script verifies that the
single-target watchOS companion is embedded in PlugIns/ with the identifiers
and install metadata MotionOS expects.
EOF
  exit 2
fi

if [[ ! -d "$IPHONE_APP" ]]; then
  echo "iPhone app bundle does not exist: $IPHONE_APP" >&2
  exit 1
fi

WATCH_APP="$IPHONE_APP/PlugIns/MotionOS.app"
if [[ ! -d "$WATCH_APP" ]]; then
  echo "Embedded Watch app missing from: $WATCH_APP" >&2
  echo "Expected a modern single-target watchOS app under PlugIns/." >&2
  exit 1
fi

read_plist() {
  /usr/libexec/PlistBuddy -c "Print :$2" "$1/Info.plist" 2>/dev/null || true
}

PHONE_ID="$(read_plist "$IPHONE_APP" CFBundleIdentifier)"
WATCH_ID="$(read_plist "$WATCH_APP" CFBundleIdentifier)"
COMPANION_ID="$(read_plist "$WATCH_APP" WKCompanionAppBundleIdentifier)"
WK_APPLICATION="$(read_plist "$WATCH_APP" WKApplication)"
RUNS_INDEPENDENTLY="$(read_plist "$WATCH_APP" WKRunsIndependentlyOfCompanionApp)"

fail=0

check_equal() {
  local label="$1"
  local actual="$2"
  local expected="$3"
  if [[ "$actual" == "$expected" ]]; then
    printf 'PASS  %-28s %s\n' "$label" "$actual"
  else
    printf 'FAIL  %-28s got=%s expected=%s\n' "$label" "$actual" "$expected" >&2
    fail=1
  fi
}

check_equal "iPhone bundle id" "$PHONE_ID" "com.sidhulyalkar.motionos"
check_equal "Watch bundle id" "$WATCH_ID" "com.sidhulyalkar.motionos.watchkitapp"
check_equal "Watch companion id" "$COMPANION_ID" "$PHONE_ID"
check_equal "WKApplication" "$WK_APPLICATION" "true"
check_equal "Runs independently" "$RUNS_INDEPENDENTLY" "false"

if [[ "$fail" -ne 0 ]]; then
  exit 1
fi

echo
echo "Companion bundle contract verified."
