#!/usr/bin/env bash
# Fail if internal tracker IDs (T-/D-/K-/H-NNNN) appear in the lines or file
# names a change adds, or in its non-merge commit messages. GitHub's own merge
# commits name the source branch, so merges are skipped.
# Usage: fleet_ids.sh <base> <head>
set -euo pipefail
base=$(git merge-base "$1" "$2")
head=$(git rev-parse "$2")

hits=$(
  {
    git log --no-merges --format='%h %B' "$base..$head" |
      perl -ne 'BEGIN{$c=""} $c=$1 if /^([0-9a-f]{7,}) /; print "commit $c: $_" if /\b[TDKH]-\d{4}\b/'
    git diff -U0 --no-color --no-ext-diff "$base" "$head" |
      perl -ne 'if (/^\+\+\+ (?:b\/)?(.*)/) { $f = $1; print "path: $f\n" if $f =~ /\b[TDKH]-\d{4}\b/; next }
                print "$f: $_" if /^\+/ && /\b[TDKH]-\d{4}\b/'
  } || true
)
if [[ -n "$hits" ]]; then
  echo "FAIL: internal tracker IDs in the change (keep them out of this public repo):"
  echo "$hits"
  exit 1
fi
echo "ok: no tracker IDs in $(git rev-list --count "$base..$head") commit(s) ${base:0:12}..${head:0:12}"
