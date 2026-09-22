#!/usr/bin/env bash
set -euo pipefail

OUT="${1:-data}"
SESSION="$(motionos simulate --out "$OUT" --sport longboard --mode calibration --duration 6)"
echo "session=$SESSION"
motionos validate "$SESSION"
motionos qc "$SESSION"
motionos replay "$SESSION" --hz 5 --frames 6
