#!/usr/bin/env bash
set -euo pipefail

FIELD_SESSION="${1:?usage: process_p2_physical.sh FIELD_SESSION CONTROLLED_SESSION SPEC [RECEIPT]}"
CONTROLLED_SESSION="${2:?usage: process_p2_physical.sh FIELD_SESSION CONTROLLED_SESSION SPEC [RECEIPT]}"
SPEC="${3:?usage: process_p2_physical.sh FIELD_SESSION CONTROLLED_SESSION SPEC [RECEIPT]}"
RECEIPT="${4:-$FIELD_SESSION/p2-physical-receipt.json}"

motionos validate-p2-physical \
  "$FIELD_SESSION" \
  "$CONTROLLED_SESSION" \
  "$SPEC" \
  --receipt "$RECEIPT"

echo
echo "p2_physical_receipt=$RECEIPT"
