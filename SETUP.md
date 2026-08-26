# Branch snapshot backups: setup runbook

Every push to any branch, in any listed repo, uploads a zip of that branch's code to
`s3://git-projects-backups/<owner>/<repo>/<branch>/<timestamp>-<sha>.zip`.

Everything here runs on the AWS CLI, `git` over SSH, and the GitHub web UI. There is no
GitHub CLI, no personal access token, and no Python dependency.

Phases 1 and 2 are complete. Start at phase 3.

---

## Phase 1: AWS (done)

### 1.1 Confirm the bucket and its region

```bash
aws s3api get-bucket-location --bucket git-projects-backups
```

A `null` result means `us-east-1`. Anything else is the literal region name. It has to match
the `aws-region` default in the workflow, or every upload fails with a confusing redirect error.

### 1.2 Block public access

```bash
aws s3api put-public-access-block --bucket git-projects-backups \
  --public-access-block-configuration \
  BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
```

Encryption at rest is already on. S3 applies SSE-S3 to new objects by default.

### 1.3 Set a lifecycle rule

Without one, every push to every branch across sixteen repos adds an object that never goes away.

```bash
cat > /tmp/lifecycle.json <<'JSON'
{
  "Rules": [{
    "ID": "expire-snapshots",
    "Status": "Enabled",
    "Filter": { "Prefix": "" },
    "Expiration": { "Days": 90 },
    "AbortIncompleteMultipartUpload": { "DaysAfterInitiation": 7 }
  }]
}
JSON

aws s3api put-bucket-lifecycle-configuration \
  --bucket git-projects-backups \
  --lifecycle-configuration file:///tmp/lifecycle.json
```

### 1.4 Create the IAM user

Write-only, one bucket. If the key leaks, the worst anyone can do is write junk into it.
They cannot read your code or delete anything.

```bash
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

aws iam create-policy --policy-name gh-snapshot-put --policy-document '{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Action": "s3:PutObject",
    "Resource": "arn:aws:s3:::git-projects-backups/*"
  }]
}'

aws iam create-user --user-name github-actions-snapshot
aws iam attach-user-policy --user-name github-actions-snapshot \
  --policy-arn "arn:aws:iam::${ACCOUNT_ID}:policy/gh-snapshot-put"

aws iam create-access-key --user-name github-actions-snapshot
```

Keep `AccessKeyId` and `SecretAccessKey` to hand. You paste them into GitHub in phase 4.

---

## Phase 2: publish the central repo (done)

The repo is public at `Snehal-Turka/gh-workflows`, tagged `v1`. Public matters, because a
private reusable workflow can only be called by repos under the same owner, and yours span
seven. The file contains no secrets.

Nothing works until the `v1` tag exists, since every caller references `@v1`.

---

## Phase 3: check SSH access

`rollout.sh` clones and pushes over SSH, so it needs a key that reaches all sixteen repos.
Your `~/.ssh/config` binds keys to host aliases rather than to `github.com`, and the alias
that reaches every repo is `github-turka`. That is the script's default. Override it with
`SSH_HOST=github-other ./rollout.sh` if that ever changes.

```bash
cd ~/Documents/Projects/gh-workflows/bootstrap
./rollout.sh --check
```

Every line should print a branch name. `NO ACCESS` means that alias cannot read that repo.
Note that this proves read access. Pushing also needs write access, and a protected default
branch rejects a direct push regardless.

---

## Phase 4: pilot on one repo

Prove the whole path works before touching the other fifteen. `repos.txt` already holds the
single pilot repo, with the full list parked in `repos.full.txt`.

### 4.1 Add the secrets first

Go to https://github.com/3d-print-store/documentation/settings/secrets/actions and add two
repository secrets:

- `AWS_ACCESS_KEY_ID`
- `AWS_SECRET_ACCESS_KEY`

Do this before the rollout. The rollout commit is itself a push, so it triggers the workflow
immediately, and a run that starts without credentials just fails.

### 4.2 Run the rollout

```bash
cd ~/Documents/Projects/gh-workflows/bootstrap
cat repos.txt          # expect: 3d-print-store/documentation
./rollout.sh
```

The script clones each repo shallowly into a temp directory, drops in the caller workflow,
commits, and pushes to the default branch. It skips repos where the file is already current.

### 4.3 Verify

Watch the run at https://github.com/3d-print-store/documentation/actions, then confirm the
object landed:

```bash
aws s3 ls --recursive s3://git-projects-backups/3d-print-store/
```

You should see one object under `3d-print-store/documentation/main/`.

| Symptom | Cause |
|---|---|
| `AccessDenied` on upload | IAM policy ARN or bucket name mismatch in step 1.4 |
| A redirect or region error | `aws-region` in the workflow does not match the bucket |
| `workflow was not found` | The `v1` tag was never pushed, or the central repo is private |
| `Secret AWS_ACCESS_KEY_ID is required` | The secrets were not added before the push |
| `push rejected` from the script | Branch protection on the default branch, or no write access |

---

## Phase 5: roll out to everything

### 5.1 Add secrets to the remaining fifteen repos

Same two secrets, same values. `./rollout.sh` prints every settings URL at the end of its run,
so you can work down that list.

### 5.2 Restore the full list and run it

```bash
mv repos.full.txt repos.txt
./rollout.sh
```

Watch the output for `SKIP` and `FAILED` lines.

### 5.3 Confirm the spread

```bash
aws s3 ls --recursive s3://git-projects-backups/ | awk '{print $4}' | cut -d/ -f1-2 | sort -u
```

Only repos whose default branch received the rollout commit appear immediately. The rest
show up as people push to them.

---

## Ongoing

### Change the workflow for all repos at once

Edit it in the central repo, then move the tag. The sixteen callers pick it up on their next
push, and you never touch them again.

```bash
git commit -am "..." && git push
git tag -f v1 && git push -f origin v1
```

### Add a new repo

Append `owner/repo` to `repos.txt`, add the two secrets in its settings, and re-run
`./rollout.sh`. It is safe to re-run across the whole list, since repos that already have the
current file are skipped without a commit.

### Rotate the AWS key

Create a new access key, update the secret in all sixteen repos, then delete the old key with
`aws iam delete-access-key`. This is the part that hurts, and it is the reason to move to OIDC
once the POC proves out.

## Known gaps

- The AWS key lives in all sixteen repos. Anyone with write access to any of them can read it
  out through a workflow. This is the cost of the access-key approach, and OIDC removes it.
- Tag pushes are not backed up, only branches.
- Nothing dedupes. Ten pushes to a branch in an hour produce ten near-identical zips.
- Deleting a branch leaves its zips in place until the lifecycle rule expires them.
