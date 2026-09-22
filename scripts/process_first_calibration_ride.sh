#!/usr/bin/env bash
set -euo pipefail

SPEC="${1:?usage: process_first_calibration_ride.sh SPEC REPORT [evidence|qualify]}"
REPORT="${2:?missing REPORT}"
MODE="${3:-evidence}"

case "$MODE" in
  evidence)
    motionos validate-first-ride \
      "$SPEC" \
      --report "$REPORT" \
      --evidence-only
    ;;
  qualify)
    motionos validate-first-ride \
      "$SPEC" \
      --report "$REPORT"
    ;;
  *)
    echo "mode must be 'evidence' or 'qualify'" >&2
    exit 2
    ;;
esac

echo
echo "first_ride_report=$REPORT"
