#!/usr/bin/env bash
set -euo pipefail

JOURNAL="${1:?usage: scripts/process_watch_smoke.sh WATCH_JSONL [OUT_ROOT] [MIN_DURATION_S] [--require-hr]}"
OUT_ROOT="${2:-data/watch-smoke}"
MIN_DURATION="${3:-30}"
REQUIRE_HR="${4:-}"

mkdir -p "$OUT_ROOT"

SESSION="$(motionos import-watch-journal "$JOURNAL" --out "$OUT_ROOT")"
REPORT="$SESSION/watch-smoke-report.json"

ARGS=(
  validate-watch-smoke
  "$SESSION"
  --min-duration "$MIN_DURATION"
  --report "$REPORT"
)

if [[ "$REQUIRE_HR" == "--require-hr" ]]; then
  ARGS+=(--require-hr)
elif [[ -n "$REQUIRE_HR" ]]; then
  echo "unknown fourth argument: $REQUIRE_HR" >&2
  exit 2
fi

echo "session=$SESSION"
motionos "${ARGS[@]}"

echo
echo "report=$REPORT"
echo "NOTE: watch-smoke-v1 is non-qualifying and must not be reported as P0."
