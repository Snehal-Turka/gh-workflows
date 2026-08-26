#!/usr/bin/env bash
# Adds the snapshot workflow and AWS secrets to every repo in repos.txt.
# Safe to re-run: updates the file in place instead of duplicating it.
set -euo pipefail

cd "$(dirname "$0")"
: "${AWS_ACCESS_KEY_ID:?export AWS_ACCESS_KEY_ID first}"
: "${AWS_SECRET_ACCESS_KEY:?export AWS_SECRET_ACCESS_KEY first}"

PATH_IN_REPO=".github/workflows/snapshot-to-s3.yml"
CONTENT_B64="$(base64 < caller.yml | tr -d '\n')"

while read -r repo; do
  [ -z "$repo" ] && continue
  case "$repo" in \#*) continue ;; esac
  printf '\n=== %s\n' "$repo"

  if ! branch="$(gh repo view "$repo" --json defaultBranchRef -q .defaultBranchRef.name 2>/dev/null)" \
     || [ -z "$branch" ] || [ "$branch" = "null" ]; then
    echo "  SKIP: no access, or repo is empty"
    continue
  fi

  gh secret set AWS_ACCESS_KEY_ID     --repo "$repo" --body "$AWS_ACCESS_KEY_ID"
  gh secret set AWS_SECRET_ACCESS_KEY --repo "$repo" --body "$AWS_SECRET_ACCESS_KEY"
  echo "  secrets set"

  sha="$(gh api "repos/$repo/contents/$PATH_IN_REPO?ref=$branch" -q .sha 2>/dev/null || true)"
  args=(-X PUT "repos/$repo/contents/$PATH_IN_REPO"
        -f message="ci: back up branch snapshots to S3"
        -f content="$CONTENT_B64"
        -f branch="$branch")
  [ -n "$sha" ] && args+=(-f sha="$sha")

  if gh api "${args[@]}" >/dev/null; then
    echo "  workflow committed to $branch"
  else
    echo "  FAILED to commit workflow"
  fi
done < repos.txt
