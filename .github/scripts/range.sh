#!/usr/bin/env bash
# Print base=/head= (GITHUB_OUTPUT format) for the commits this run checks.
# Pull request: merge-base of the PR's base and head. Push: the push's previous
# tip, or the parent commit when there is none (new branch, force-push).
set -euo pipefail
if [[ -n "${PR_HEAD:-}" ]]; then
  head=$PR_HEAD
  base=$(git merge-base "$PR_BASE" "$PR_HEAD")
else
  head=$(git rev-parse HEAD)
  base=${BEFORE:-}
  if [[ -z "$base" || "$base" =~ ^0+$ ]] || ! git cat-file -e "$base^{commit}" 2>/dev/null; then
    base=$(git rev-parse "$head~1")
  fi
fi
echo "base=$base"
echo "head=$head"
