#!/usr/bin/env bash
# Commit the snapshot workflow to every repo in repos.txt, over SSH. No token needed.
#
#   ./rollout.sh --check     report which repos your SSH key can reach
#   ./rollout.sh             clone, add the workflow, push
#
# Secrets are not handled here. GitHub's API is the only way to set them and it
# does not accept SSH keys, so paste them into each repo's settings page. The
# script prints the links at the end.
set -euo pipefail

cd "$(dirname "$0")"
export GIT_TERMINAL_PROMPT=0
export GIT_SSH_COMMAND="${GIT_SSH_COMMAND:-ssh -o BatchMode=yes}"

# Host alias from ~/.ssh/config, not github.com, because the key that reaches these
# repos is bound to an alias. Override with SSH_HOST=... for a different account.
SSH_HOST="${SSH_HOST:-github-turka}"

WORKFLOW_PATH=".github/workflows/snapshot-to-s3.yml"
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

repos() { grep -v '^[[:space:]]*\(#\|$\)' repos.txt; }

# Prints the default branch name, or nothing if the remote is unreachable.
default_branch() {
  git ls-remote --symref "git@$SSH_HOST:$1.git" HEAD 2>/dev/null \
    | awk '/^ref:/ { sub("refs/heads/", "", $2); print $2; exit }' || true
}

if [ "${1:-}" = "--check" ]; then
  unreachable=0
  echo "Repos your SSH key can reach:"
  echo
  while read -r repo; do
    branch="$(default_branch "$repo")"
    printf '  %-52s %s\n' "$repo" "${branch:-NO ACCESS}"
    if [ -z "$branch" ]; then
      unreachable=$((unreachable + 1))
    fi
  done < <(repos)
  if [ "$unreachable" -gt 0 ]; then
    echo
    echo "$unreachable repo(s) unreachable over $SSH_HOST. Try another alias from"
    echo "~/.ssh/config with: SSH_HOST=github-other ./rollout.sh --check"
    exit 1
  fi
  exit 0
fi

while read -r repo; do
  printf '\n=== %s\n' "$repo"

  branch="$(default_branch "$repo")"
  if [ -z "$branch" ]; then
    echo "  SKIP: no access, or the repo is empty"
    continue
  fi

  dir="$WORKDIR/$(echo "$repo" | tr / _)"
  if ! git clone --quiet --depth 1 --single-branch --branch "$branch" \
       "git@$SSH_HOST:$repo.git" "$dir"; then
    echo "  FAILED: clone"
    continue
  fi

  mkdir -p "$dir/.github/workflows"
  cp caller.yml "$dir/$WORKFLOW_PATH"

  if git -C "$dir" diff --quiet -- "$WORKFLOW_PATH" && \
     [ -z "$(git -C "$dir" ls-files --others --exclude-standard -- "$WORKFLOW_PATH")" ]; then
    echo "  already up to date on $branch"
    continue
  fi

  git -C "$dir" add "$WORKFLOW_PATH"
  git -C "$dir" commit --quiet -m "ci: back up branch snapshots to S3"

  if git -C "$dir" push --quiet origin "$branch"; then
    echo "  pushed to $branch"
  else
    echo "  FAILED: push rejected (branch protection, or no write access)"
  fi
done < <(repos)

echo
echo "Workflow files are in place. Set these two secrets on each repo:"
echo "  AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY"
echo "Paste them at:"
while read -r repo; do
  echo "  https://github.com/$repo/settings/secrets/actions"
done < <(repos)
