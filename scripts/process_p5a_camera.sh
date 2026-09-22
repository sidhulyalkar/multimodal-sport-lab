#!/usr/bin/env bash
set -euo pipefail

CAMERA_DIR="${1:?usage: process_p5a_camera.sh CAMERA_DIR OUT_ROOT [MIN_DURATION] [WATCH_SESSION] [SYNC_WINDOWS]}"
OUT_ROOT="${2:-data/camera}"
MIN_DURATION="${3:-600}"
WATCH_SESSION="${4:-}"
SYNC_WINDOWS="${5:-}"

mkdir -p "$OUT_ROOT"

SESSION="$(
  motionos import-camera-evidence \
    "$CAMERA_DIR" \
    --out "$OUT_ROOT"
)"

RECEIPT="$SESSION/camera-capture-receipt.json"

echo "session=$SESSION"

echo
echo "== camera/video/Vision capture qualification =="
motionos validate-camera \
  "$SESSION" \
  --min-duration "$MIN_DURATION" \
  --receipt "$RECEIPT"

echo
echo "receipt=$RECEIPT"

if [[ -n "$WATCH_SESSION" || -n "$SYNC_WINDOWS" ]]; then
  if [[ -z "$WATCH_SESSION" || -z "$SYNC_WINDOWS" ]]; then
    echo "WATCH_SESSION and SYNC_WINDOWS must be supplied together" >&2
    exit 2
  fi

  SYNC_RECEIPT="$SESSION/camera-to-watch-clock-sync.json"

  echo
  echo "== camera -> Watch deliberate-landmark clock mapping =="
  motionos derive-clock-sync \
    "$WATCH_SESSION" \
    "$SESSION" \
    "$SYNC_WINDOWS" \
    "$SYNC_RECEIPT" \
    --reference-stream /body/watch/imu \
    --target-stream /camera/pose_motion \
    --target-keys motion_m

  echo
  echo "clock_sync=$SYNC_RECEIPT"
fi
