#!/usr/bin/env bash
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/.." && pwd)"
EXPECTED_REF="${1:-origin/fix/apple-bootstrap-package-resolution}"

if git -C "$REPO_ROOT" remote get-url origin >/dev/null 2>&1; then
  git -C "$REPO_ROOT" fetch --quiet origin || {
    echo "FAIL: unable to refresh origin before baseline check." >&2
    exit 2
  }
fi

if ! EXPECTED_SHA="$(git -C "$REPO_ROOT" rev-parse --verify "$EXPECTED_REF^{commit}" 2>/dev/null)"; then
  echo "FAIL: expected baseline does not resolve: $EXPECTED_REF" >&2
  exit 2
fi

HEAD_SHA="$(git -C "$REPO_ROOT" rev-parse HEAD)"
BRANCH="$(git -C "$REPO_ROOT" branch --show-current)"
DIRTY="$(git -C "$REPO_ROOT" status --porcelain)"

echo "== MotionOS agent baseline check =="
echo "Worktree: $REPO_ROOT"
echo "Branch:   ${BRANCH:-detached}"
echo "HEAD:     $HEAD_SHA"
echo "Expected: $EXPECTED_REF"
echo "          $EXPECTED_SHA"
echo

if [[ -n "$DIRTY" ]]; then
  echo "FAIL: worktree is not clean before assignment start:" >&2
  git -C "$REPO_ROOT" status --short >&2
  exit 3
fi

if [[ "$HEAD_SHA" == "$EXPECTED_SHA" ]]; then
  echo "PASS: worktree is exactly at the expected integration baseline."
  exit 0
fi

read -r AHEAD BEHIND < <(
  git -C "$REPO_ROOT" rev-list --left-right --count "HEAD...$EXPECTED_REF"
)

if [[ "$AHEAD" == "0" && "$BEHIND" != "0" ]]; then
  cat >&2 <<EOF
FAIL: this worktree is stale by $BEHIND commit(s).

Before auditing or starting a new task:
  git merge --ff-only $EXPECTED_REF
  bash scripts/agent_baseline_check.sh $EXPECTED_REF

Do not report PASS/FAIL findings against the stale snapshot as current baseline findings.
EOF
  exit 4
fi

cat >&2 <<EOF
FAIL: this worktree is not exactly at the expected baseline.
HEAD-only commits:     $AHEAD
baseline-only commits: $BEHIND

If this is a new assignment, reconcile the branch explicitly before proceeding.
If this is already an in-progress task branch, do not reinterpret its results as
an audit of the current integration baseline.
EOF
exit 5
