#!/usr/bin/env bash
set -euo pipefail

SPEC="${1:?usage: finalize_m0_run.sh RUN_SPEC OUT_DIR [REPLAY_HZ] [REPLAY_TARGET]}"
OUT_DIR="${2:-data/calibration-run}"
REPLAY_HZ="${3:-10}"
REPLAY_TARGET="${4:-web/replay-lab/session.json}"

bash scripts/process_calibration_run.sh \
  "$SPEC" \
  "$OUT_DIR" \
  "$REPLAY_HZ" \
  "$REPLAY_TARGET"

echo
echo "== validate strict M0 physical-integration closure =="
motionos validate-m0-closure \
  "$OUT_DIR/run.json" \
  --receipt "$OUT_DIR/m0-closure-receipt.json"

echo
echo "closure_receipt=$OUT_DIR/m0-closure-receipt.json"
echo "M0 physical integration closure passed."
