#!/usr/bin/env bash
set -euo pipefail

JOURNAL="${1:?usage: scripts/process_p0_watch.sh WATCH_JSONL [OUT_ROOT] [MIN_DURATION_S]}"
OUT_ROOT="${2:-data/p0}"
MIN_DURATION="${3:-60}"

mkdir -p "$OUT_ROOT"

SESSION="$(motionos import-watch-journal "$JOURNAL" --out "$OUT_ROOT")"
RECEIPT="$SESSION/p0-receipt.json"

echo "session=$SESSION"
motionos validate-p0   "$SESSION"   --min-duration "$MIN_DURATION"   --receipt "$RECEIPT"

echo
echo "receipt=$RECEIPT"
