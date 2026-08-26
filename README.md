# gh-workflows

One reusable GitHub Actions workflow, shared by every repo that backs up its code to S3.

On every push to any branch, the pushed repo uploads a zip of that branch to:

```
s3://git-projects-backups/<owner>/<repo>/<branch>/<timestamp>-<sha>.zip
```

The logic lives here, once. Each backed-up repo carries only a nine line file that calls it,
so changing how backups work means editing this repo, not seventeen others.

| Path | What it is |
|---|---|
| `.github/workflows/snapshot-to-s3.yml` | The reusable workflow. All the real logic. |
| `bootstrap/caller.yml` | The file each backed-up repo gets a copy of. |
| `bootstrap/repos.txt` | Which repos are covered. |
| `bootstrap/rollout.sh` | Copies `caller.yml` into every repo in the list, over SSH. |
| `SETUP.md` | How the S3 bucket, IAM user, and this repo were originally set up. |

---

## Add a repo to the backups

### What you need first

- Write access to the repo you are adding, and an SSH key that reaches it. Check with
  `cd bootstrap && ./rollout.sh --check` once you have added the line in step 2.
- The values of the AWS access key pair. GitHub will not show you an existing secret, so get
  them from whoever set this up, or create a fresh key for the `github-actions-snapshot`
  IAM user and update every repo.

### 1. Add the two secrets to the new repo

In the repo, go to Settings, Secrets and variables, Actions, and add:

- `AWS_ACCESS_KEY_ID`
- `AWS_SECRET_ACCESS_KEY`

Do this first. Step 3 pushes a commit, which immediately triggers a backup run, and a run
that starts without credentials fails.

### 2. Add the repo to the list

```bash
cd ~/Documents/Projects/gh-workflows/bootstrap
echo "owner/new-repo" >> repos.txt
./rollout.sh --check
```

Every line should print a branch name. `NO ACCESS` on the new one means your SSH key cannot
reach it. The default SSH host alias is `github-turka`; override it with
`SSH_HOST=github-other ./rollout.sh --check` if the repo needs a different account.

### 3. Run the rollout

```bash
./rollout.sh
```

Repos already carrying the current file are skipped without a commit, so only the new one
gets touched. Look for `pushed to <branch>` on it.

### 4. Verify

The push from step 3 triggers the first backup. Watch it on the repo's Actions tab, then:

```bash
aws s3 ls --recursive s3://git-projects-backups/owner/new-repo/
```

One object should appear, under the repo's default branch.

### If the run fails

| Symptom | Cause |
|---|---|
| `Secret AWS_ACCESS_KEY_ID is required` | Step 1 was skipped, or the secret name is misspelled |
| `AccessDenied` on upload | The IAM user cannot write to this bucket |
| A redirect or region error | `aws-region` in the workflow does not match the bucket |
| `workflow was not found` | This repo is not public, or the `v1` tag is missing |
| `push rejected` from the script | Branch protection on the default branch, or no write access |

---

## Remove a repo from the backups

Deleting its line from `repos.txt` only stops future rollouts from touching it. The workflow
file is already in that repo and keeps running. To actually stop its backups, delete
`.github/workflows/snapshot-to-s3.yml` from the repo itself.

Existing zips stay in S3 until the bucket's 90 day lifecycle rule expires them.

## Change how backups work, everywhere at once

Edit `.github/workflows/snapshot-to-s3.yml` here, then move the tag. Every caller references
`@v1`, so they all pick up the change on their next push.

```bash
git commit -am "..." && git push
git tag -f v1 && git push -f origin v1
```

Only edit `bootstrap/caller.yml` when the call itself changes, such as adding a trigger or an
input. That does require a rollout to all repos, since the file lives in each one.

## Re-run a backup without pushing code

Each repo's Actions tab has a "Snapshot to S3" workflow with a "Run workflow" button.

## Notes for whoever inherits this

- The AWS key is duplicated into every covered repo. Anyone with write access to any of them
  can read it out through a workflow, and rotating it means updating all of them. Moving to
  OIDC removes both problems.
- `caller.yml` passes both secrets by name rather than using `secrets: inherit`. `inherit`
  only works when caller and callee share an owner, and these repos span seven.
- `rollout.sh` needs `git` and SSH. It does not use the GitHub CLI or any token.
