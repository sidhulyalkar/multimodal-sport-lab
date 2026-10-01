#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 1 || $# -gt 2 ]]; then
  echo "Usage: bash scripts/sync_agent_lane.sh <lane> [base-ref]" >&2
  exit 2
fi

LANE="$1"
BASE_REF="${2:-origin/fix/apple-bootstrap-package-resolution}"

case "$LANE" in
  apple|sensors|models|product|verify) ;;
  *)
    echo "Unknown lane: $LANE" >&2
    exit 2
    ;;
esac

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/.." && pwd)"
PARENT="$(cd "$REPO_ROOT/.." && pwd)"
FLEET_ROOT="${MOTIONOS_AGENT_WORKTREES:-$PARENT/motionos-agents}"
LANE_ROOT="$FLEET_ROOT/$LANE"

if [[ ! -d "$LANE_ROOT" ]]; then
  echo "Lane worktree not found: $LANE_ROOT" >&2
  exit 2
fi

git -C "$LANE_ROOT" fetch origin

if [[ -n "$(git -C "$LANE_ROOT" status --porcelain)" ]]; then
  echo "REFUSE: $LANE worktree is dirty." >&2
  git -C "$LANE_ROOT" status --short >&2
  exit 3
fi

read -r ahead behind < <(
  git -C "$LANE_ROOT" rev-list --left-right --count "HEAD...$BASE_REF"
)

if [[ "$ahead" != "0" ]]; then
  cat >&2 <<EOF
REFUSE: $LANE has $ahead lane-local commit(s).
Do not auto-sync an in-progress lane. Merge/rebase/archive it explicitly.
EOF
  exit 4
fi

if [[ "$behind" == "0" ]]; then
  echo "$LANE already matches $BASE_REF."
  exit 0
fi

git -C "$LANE_ROOT" merge --ff-only "$BASE_REF"
echo "$LANE fast-forwarded to $(git -C "$LANE_ROOT" rev-parse --short HEAD)."
