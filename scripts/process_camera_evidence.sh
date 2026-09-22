#!/usr/bin/env bash
set -euo pipefail

JOURNAL="${1:?usage: process_camera_evidence.sh CAMERA_JSONL VIDEO OUT_ROOT [MIN_DURATION] [METADATA] [SPORT]}"
VIDEO="${2:?video path required}"
OUT_ROOT="${3:-data/camera}"
MIN_DURATION="${4:-600}"
METADATA="${5:-}"
SPORT="${6:-camera-qualification}"

mkdir -p "$OUT_ROOT"

IMPORT_ARGS=(
  import-camera-evidence
  "$JOURNAL"
  "$VIDEO"
  --out "$OUT_ROOT"
  --sport "$SPORT"
)

if [[ -n "$METADATA" ]]; then
  IMPORT_ARGS+=(--metadata "$METADATA")
fi

SESSION="$(motionos "${IMPORT_ARGS[@]}")"
RECEIPT="$SESSION/camera-capture-receipt.json"

echo "session=$SESSION"
echo
echo "== camera evidence qualification =="
motionos validate-camera \
  "$SESSION" \
  --min-duration "$MIN_DURATION" \
  --receipt "$RECEIPT"

echo
echo "receipt=$RECEIPT"
