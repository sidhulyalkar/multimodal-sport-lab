#!/usr/bin/env bash
set -euo pipefail

SOURCE="${1:?usage: process_operator_evidence.sh OPERATOR_DIR [OUTPUT_RECEIPT]}"
OUTPUT="${2:-$SOURCE/operator-evidence-receipt.json}"

motionos validate-operator-evidence \
  "$SOURCE" \
  --receipt "$OUTPUT"

echo
echo "operator_receipt=$OUTPUT"
