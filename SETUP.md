# Branch snapshot backups: setup runbook

Every push to any branch, in any listed repo, uploads a zip of that branch's code to
`s3://git-projects-backups/<owner>/<repo>/<branch>/<timestamp>-<sha>.zip`.

Everything here runs on the AWS CLI, `git` over SSH, and the GitHub web UI. There is no
GitHub CLI, no personal access token, and no Python dependency.

This document is the record of the original setup. For day to day work, adding a repo to the
backups or changing how they run, see [README.md](README.md).

**Phases 1 to 4 are complete.** The pilot repo `3d-print-store/documentation` is backing up
on every push. What remains is phase 5, rolling out to the other sixteen.

`repos.txt` holds the canonical list of seventeen repos, all confirmed reachable over SSH.
Three of them default to `dev` rather than `main`: `hire-link/finops`, `hire-link/admin-panel`
and `Upwork-Extension/upwrok-auto-submit-gig-extension`. The script reads each repo's own
default branch, so this needs no special handling.

---

## Phase 5: roll out to everything

### 5.1 Add secrets to the remaining sixteen repos

Each repo needs `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY` under Settings, Secrets and
variables, Actions. Same values as the pilot.

Do this before the rollout. The rollout commit is itself a push, so it triggers the workflow
immediately, and a run that starts without credentials fails.

Running `./rollout.sh` prints every settings URL at the end, so you can work down that list.

- https://github.com/turka-meet-bot/meet_bot/settings/secrets/actions
- https://github.com/3d-print-store/web-app/settings/secrets/actions
- https://github.com/hire-link/finops/settings/secrets/actions
- https://github.com/hire-link/mobile/settings/secrets/actions
- https://github.com/hire-link/hirelink-backend/settings/secrets/actions
- https://github.com/hire-link/admin-panel/settings/secrets/actions
- https://github.com/Upwork-Extension/upwork-backend/settings/secrets/actions
- https://github.com/Upwork-Extension/graphQL/settings/secrets/actions
- https://github.com/Upwork-Extension/upwrok-auto-submit-gig-extension/settings/secrets/actions
- https://github.com/gouravturka/water-tank-app/settings/secrets/actions
- https://github.com/gouravturka/water-tank-analysis/settings/secrets/actions
- https://github.com/gouravturka/iot/settings/secrets/actions
- https://github.com/Snehal-Turka/healthcare/settings/secrets/actions
- https://github.com/Verify-Staff/verify-staff-backend/settings/secrets/actions
- https://github.com/Verify-Staff/verify-staff-web/settings/secrets/actions
- https://github.com/gouravturka/linkdin-outreach/settings/secrets/actions

### 5.2 Run the rollout

```bash
cd ~/Documents/Projects/gh-workflows/bootstrap
./rollout.sh
```

The pilot repo is in the list too. It already has the current file, so the script skips it
without a commit.

Watch the output for these lines:

| Line | Meaning |
|---|---|
| `pushed to <branch>` | Workflow committed, first backup starting now |
| `already up to date` | Nothing to do, the file is current |
| `SKIP: no access` | The `github-turka` key cannot read that repo |
| `FAILED: push rejected` | Branch protection on the default branch, or no write access |

### 5.3 Confirm the spread

```bash
aws s3 ls --recursive s3://git-projects-backups/ | awk '{print $4}' | cut -d/ -f1-2 | sort -u
```

Only repos whose default branch received the rollout commit appear immediately. The rest
show up as people push to them.

---

## Ongoing

### Change the workflow for all repos at once

Edit it in the central repo, then move the tag. The seventeen callers pick it up on their next
push, and you never touch them again.

```bash
git commit -am "..." && git push
git tag -f v1 && git push -f origin v1
```

### Add or drop a repo

See [README.md](README.md), which covers both start to finish.

### Rotate the AWS key

Create a new access key, update the secret in all seventeen repos, then delete the old key with
`aws iam delete-access-key`. This is the part that hurts, and it is the reason to move to OIDC
once the POC proves out.

### Check the bucket size after a week

Seventeen repos pushing all day produces more objects than you expect. If the 90 day expiry
looks too generous once real traffic lands, shorten the lifecycle rule.

---

## What phases 1 to 4 set up

### AWS

Bucket `git-projects-backups` with public access blocked, a 90 day expiry lifecycle rule, and
an IAM user `github-actions-snapshot` holding one permission, `s3:PutObject` on that one
bucket. If the key leaks, the worst anyone can do is write junk into it. They cannot read your
code or delete anything.

### The central repo

`Snehal-Turka/gh-workflows` is public and tagged `v1`. Public matters, because a private
reusable workflow can only be called by repos under the same owner, and yours span seven.
Nothing works until the `v1` tag exists, since every caller references `@v1`.

### Why the caller passes secrets by name

`caller.yml` names both secrets explicitly rather than using `secrets: inherit`:

```yaml
    secrets:
      AWS_ACCESS_KEY_ID: ${{ secrets.AWS_ACCESS_KEY_ID }}
      AWS_SECRET_ACCESS_KEY: ${{ secrets.AWS_SECRET_ACCESS_KEY }}
```

`inherit` only passes secrets to a reusable workflow under the same owner. Your repos span
seven owners calling one central repo, so every call crosses that boundary and `inherit`
silently passes nothing. The run then fails before it starts, with
`Secret AWS_ACCESS_KEY_ID is required, but not provided while calling`.

### SSH, not github.com

`rollout.sh` clones and pushes over SSH. Your `~/.ssh/config` binds keys to host aliases
rather than to `github.com`, and `github-turka` is the alias that reaches all seventeen repos.
That is the script's default. Override it with `SSH_HOST=github-other ./rollout.sh`.

```bash
./rollout.sh --check     # every line should print a branch name
```

---

## Troubleshooting a failed run

| Symptom | Cause |
|---|---|
| `Secret AWS_ACCESS_KEY_ID is required` | Secrets not added to that repo, or the caller uses `secrets: inherit` |
| `AccessDenied` on upload | IAM policy ARN or bucket name mismatch |
| A redirect or region error | `aws-region` in the workflow does not match the bucket |
| `workflow was not found` | The `v1` tag was never pushed, or the central repo is private |
| `push rejected` from the script | Branch protection on the default branch, or no write access |

## Known gaps

- The AWS key lives in all seventeen repos. Anyone with write access to any of them can read it
  out through a workflow. This is the cost of the access-key approach, and OIDC removes it.
- Tag pushes are not backed up, only branches.
- Nothing dedupes. Ten pushes to a branch in an hour produce ten near-identical zips.
- Deleting a branch leaves its zips in place until the lifecycle rule expires them.
