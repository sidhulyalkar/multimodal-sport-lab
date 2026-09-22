#!/usr/bin/env bash
set -euo pipefail

POD_JOURNAL="${1:?usage: process_p1_pod.sh POD_JSONL WATCH_SESSION SYNC_WINDOWS OUT_ROOT [PROFILE] [MIN_DURATION] [RATE_TOLERANCE] [MAX_GAP_MULTIPLE] [MAX_SYNC_RESIDUAL_MS]}"
WATCH_SESSION="${2:?missing WATCH_SESSION}"
SYNC_WINDOWS="${3:?missing SYNC_WINDOWS}"
OUT_ROOT="${4:-data/p1}"
PROFILE="${5:-}"
MIN_DURATION="${6:-600}"
RATE_TOLERANCE="${7:-0.05}"
MAX_GAP_MULTIPLE="${8:-2.0}"
MAX_SYNC_RESIDUAL_MS="${9:-20}"

mkdir -p "$OUT_ROOT"

IMPORT_ARGS=(
  import-pod-journal
  "$POD_JOURNAL"
  --out "$OUT_ROOT"
)

if [[ -n "$PROFILE" ]]; then
  IMPORT_ARGS+=(--profile "$PROFILE")
fi

SESSION="$(motionos "${IMPORT_ARGS[@]}")"
CAPTURE_RECEIPT="$SESSION/p1-capture-receipt.json"
SYNC_OBSERVATIONS="$SESSION/p1-sync-observations.json"
FINAL_RECEIPT="$SESSION/p1-receipt.json"

echo "session=$SESSION"

echo
echo "== capture-only qualification =="
motionos validate-p1 \
  "$SESSION" \
  --min-duration "$MIN_DURATION" \
  --capture-only \
  --receipt "$CAPTURE_RECEIPT"

echo
echo "== derive explicit pod→Watch impulse correspondences =="
motionos derive-p1-sync \
  "$WATCH_SESSION" \
  "$SESSION" \
  "$SYNC_WINDOWS" \
  "$SYNC_OBSERVATIONS"

echo
echo "== full frozen P1 gate =="
motionos validate-p1 \
  "$SESSION" \
  --min-duration "$MIN_DURATION" \
  --rate-tolerance "$RATE_TOLERANCE" \
  --max-gap-multiple "$MAX_GAP_MULTIPLE" \
  --sync-observations "$SYNC_OBSERVATIONS" \
  --max-sync-residual-ms "$MAX_SYNC_RESIDUAL_MS" \
  --receipt "$FINAL_RECEIPT"

echo
echo "capture_receipt=$CAPTURE_RECEIPT"
echo "sync_observations=$SYNC_OBSERVATIONS"
echo "final_receipt=$FINAL_RECEIPT"
