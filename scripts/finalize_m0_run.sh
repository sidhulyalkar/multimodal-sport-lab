#!/usr/bin/env bash
set -euo pipefail

SPEC="${1:?usage: finalize_m0_run.sh RUN_SPEC OUT_DIR [REPLAY_HZ] [REPLAY_TARGET]}"
OUT_DIR="${2:-data/calibration-run}"
REPLAY_HZ="${3:-10}"
REPLAY_TARGET="${4:-web/replay-lab/session.json}"

mkdir -p "$OUT_DIR"

RUN_JSON="$OUT_DIR/run.json"
REPORT_JSON="$OUT_DIR/report.json"
REPLAY_JSON="$OUT_DIR/replay-session.json"
CLOSURE_JSON="$OUT_DIR/m0-closure-receipt.json"

echo "== build calibration run manifest =="
motionos build-calibration-run "$SPEC" "$RUN_JSON"

echo
echo "== build calibration evidence report =="
motionos report-calibration-run "$RUN_JSON" "$REPORT_JSON"

echo
echo "== export local Replay Lab payload =="
motionos export-replay-lab \
  "$RUN_JSON" \
  "$REPLAY_JSON" \
  --hz "$REPLAY_HZ"

echo
echo "== validate strict M0 physical-integration closure =="
motionos validate-m0-closure \
  "$RUN_JSON" \
  --receipt "$CLOSURE_JSON"

echo
echo "== publish qualified Replay Lab payload =="
mkdir -p "$(dirname "$REPLAY_TARGET")"
cp "$REPLAY_JSON" "$REPLAY_TARGET"

echo
echo "run=$RUN_JSON"
echo "report=$REPORT_JSON"
echo "replay=$REPLAY_JSON"
echo "closure_receipt=$CLOSURE_JSON"
echo "replay_lab_target=$REPLAY_TARGET"
echo
echo "M0 physical integration closure passed; qualified replay published."
