#!/usr/bin/env bash
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/.." && pwd)"
PARENT="$(cd "$REPO_ROOT/.." && pwd)"
FLEET_ROOT="${MOTIONOS_AGENT_WORKTREES:-$PARENT/motionos-agents}"
BASE_REF="${1:-origin/fix/apple-bootstrap-package-resolution}"

git -C "$REPO_ROOT" fetch --quiet origin

if ! BASE_SHA="$(git -C "$REPO_ROOT" rev-parse --verify "$BASE_REF^{commit}" 2>/dev/null)"; then
  echo "Base ref does not resolve: $BASE_REF" >&2
  exit 2
fi

printf "MotionOS agent fleet\n"
printf "Base: %s (%s)\n\n" "$BASE_REF" "${BASE_SHA:0:8}"
printf "%-10s %-20s %-10s %-7s %-7s %-8s\n" "lane" "branch" "head" "ahead" "behind" "dirty"
printf "%-10s %-20s %-10s %-7s %-7s %-8s\n" "----------" "--------------------" "----------" "-------" "-------" "--------"

for lane in apple sensors models product verify; do
  path="$FLEET_ROOT/$lane"
  if [[ ! -d "$path/.git" && ! -f "$path/.git" ]]; then
    printf "%-10s %-20s %-10s %-7s %-7s %-8s\n" "$lane" "missing" "-" "-" "-" "-"
    continue
  fi

  branch_name="$(git -C "$path" branch --show-current)"
  head="$(git -C "$path" rev-parse --short HEAD)"
  read -r ahead behind < <(git -C "$path" rev-list --left-right --count "HEAD...$BASE_REF")
  if [[ -n "$(git -C "$path" status --porcelain)" ]]; then
    dirty=yes
  else
    dirty=no
  fi

  printf "%-10s %-20s %-10s %-7s %-7s %-8s\n"     "$lane" "${branch_name:-detached}" "$head" "$ahead" "$behind" "$dirty"
done
