#!/usr/bin/env bash
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/.." && pwd)"
BASE_REF="${1:-$(git -C "$REPO_ROOT" branch --show-current)}"
PARENT="$(cd "$REPO_ROOT/.." && pwd)"
FLEET_ROOT="${MOTIONOS_AGENT_WORKTREES:-$PARENT/motionos-agents}"

if [[ -z "$BASE_REF" ]]; then
  echo "Unable to infer a base branch. Pass one explicitly:" >&2
  echo "  bash scripts/setup_agent_worktrees.sh <base-ref>" >&2
  exit 2
fi

if ! git -C "$REPO_ROOT" rev-parse --verify "$BASE_REF^{commit}" >/dev/null 2>&1; then
  echo "Base ref does not resolve to a commit: $BASE_REF" >&2
  exit 2
fi

if [[ -n "$(git -C "$REPO_ROOT" status --porcelain)" ]]; then
  echo "NOTE: the primary checkout has uncommitted changes."
  echo "Worktrees will still be created from committed base ref: $BASE_REF"
  echo
fi

mkdir -p "$FLEET_ROOT"

roles=(apple sensors models product verify)

echo "== MotionOS agent worktrees =="
echo "Repo:  $REPO_ROOT"
echo "Base:  $BASE_REF"
echo "Root:  $FLEET_ROOT"
echo

for role in "${roles[@]}"; do
  path="$FLEET_ROOT/$role"
  branch="agent/$role"

  if git -C "$REPO_ROOT" worktree list --porcelain | grep -Fqx "worktree $path"; then
    echo "exists: $role -> $path"
    continue
  fi

  if [[ -e "$path" ]] && [[ -n "$(ls -A "$path" 2>/dev/null || true)" ]]; then
    echo "refusing non-empty path: $path" >&2
    exit 1
  fi

  if git -C "$REPO_ROOT" show-ref --verify --quiet "refs/heads/$branch"; then
    git -C "$REPO_ROOT" worktree add "$path" "$branch"
  else
    git -C "$REPO_ROOT" worktree add -b "$branch" "$path" "$BASE_REF"
  fi

  echo "created: $role -> $path ($branch)"
done

cat <<EOF

Fleet ready.

Open one terminal/agent session per worktree:
  $FLEET_ROOT/apple
  $FLEET_ROOT/sensors
  $FLEET_ROOT/models
  $FLEET_ROOT/product
  $FLEET_ROOT/verify

Keep each task inside its assigned worktree and merge through reviewed PRs.
EOF
