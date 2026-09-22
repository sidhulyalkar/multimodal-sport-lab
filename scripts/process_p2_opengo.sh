#!/usr/bin/env bash
set -euo pipefail

SOURCE="${1:?usage: process_p2_opengo.sh OPENGO_TXT OUT_ROOT [MIN_DURATION] [SESSION_ID] [ATHLETE_ID] [SPORT]}"
OUT_ROOT="${2:-data/p2}"
MIN_DURATION="${3:-600}"
SESSION_ID="${4:-}"
ATHLETE_ID="${5:-local-athlete}"
SPORT="${6:-insole-qualification}"

mkdir -p "$OUT_ROOT"

IMPORT_ARGS=(
  import-opengo-export
  "$SOURCE"
  --out "$OUT_ROOT"
  --athlete-id "$ATHLETE_ID"
  --sport "$SPORT"
)

if [[ -n "$SESSION_ID" ]]; then
  IMPORT_ARGS+=(--session-id "$SESSION_ID")
fi

SESSION="$(motionos "${IMPORT_ARGS[@]}")"
RECEIPT="$SESSION/p2-capture-receipt.json"

echo "session=$SESSION"

echo
echo "== bilateral OpenGo capture qualification =="
motionos validate-p2 \
  "$SESSION" \
  --min-duration "$MIN_DURATION" \
  --receipt "$RECEIPT"

echo
echo "receipt=$RECEIPT"
