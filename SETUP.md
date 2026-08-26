# Branch snapshot backups: setup runbook

Every push to any branch, in any listed repo, uploads a zip of that branch's code to
`s3://git-projects-backups/<owner>/<repo>/<branch>/<timestamp>-<sha>.zip`.

Work through the phases in order. Phases 1 and 2 are one-time; phase 4 is a pilot on a
single repo before you touch the other fifteen.

---

## Phase 1: AWS

### 1.1 Confirm the bucket and its region

```bash
aws s3api get-bucket-location --bucket git-projects-backups
```

A `null` result means `us-east-1`. Anything else is the literal region name. Write it down,
you need it in step 2.1, and a mismatch there fails every upload with a confusing redirect error.

If the bucket does not exist yet:

```bash
export AWS_REGION=ap-south-1   # your choice
aws s3api create-bucket --bucket git-projects-backups \
  --region "$AWS_REGION" \
  --create-bucket-configuration LocationConstraint="$AWS_REGION"
```

For `us-east-1` only, drop the `--create-bucket-configuration` flag entirely.

### 1.2 Block public access

```bash
aws s3api put-public-access-block --bucket git-projects-backups \
  --public-access-block-configuration \
  BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
```

Encryption at rest is already on. S3 applies SSE-S3 to new objects by default.

### 1.3 Set a lifecycle rule

Do this **before** the rollout. Without it, every push to every branch across sixteen repos
adds an object that never goes away.

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

90 days is a starting point. Shorten it if the bucket grows faster than you expected.

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

Copy `AccessKeyId` and `SecretAccessKey` from that last command. The secret is shown once.

```bash
export AWS_ACCESS_KEY_ID=AKIA...
export AWS_SECRET_ACCESS_KEY=...
```

Give this user no console password and no other policies.

---

## Phase 2: publish the central repo

### 2.1 Set the region

Skip this if your bucket is in `us-east-1`. Otherwise edit
`.github/workflows/snapshot-to-s3.yml` and change the `aws-region` default:

```yaml
      aws-region:
        type: string
        default: ap-south-1
```

### 2.2 Push it and tag v1

The repo must be **public**. A private reusable workflow can only be called by repos under
the same owner, and yours span seven. The file contains no secrets.

```bash
cd ~/Documents/Projects/gh-workflows
git init -b main
git add .
git commit -m "Add reusable S3 snapshot workflow"
gh repo create Snehal-Turka/gh-workflows --public --source=. --push
git tag v1
git push origin v1
```

Nothing works until the `v1` tag exists, because every caller references `@v1`.

---

## Phase 3: check access before rolling out

### 3.1 Grant your CLI the workflow scope

Committing files under `.github/workflows/` needs it:

```bash
gh auth refresh -s workflow
```

### 3.2 Find repos you cannot reach

Orgs can block personal access tokens or require SSO authorization, so `Verify-Staff`,
`hire-link` and `Upwork-Extension` may reject you.

```bash
cd ~/Documents/Projects/gh-workflows/bootstrap
while read -r r; do
  [ -z "$r" ] && continue
  printf '%-52s' "$r"
  gh repo view "$r" --json defaultBranchRef -q .defaultBranchRef.name 2>/dev/null || echo "NO ACCESS"
done < repos.txt
```

Every line should print a branch name. For any that print `NO ACCESS`, get an org owner to
approve your token, then re-run. `rollout.sh` skips these repos rather than failing, so you
can also proceed and come back to them.

---

## Phase 4: pilot on one repo

Prove the whole path works before committing to sixteen repos.

```bash
cd ~/Documents/Projects/gh-workflows/bootstrap
cp repos.txt repos.full.txt
echo "3d-print-store/documentation" > repos.txt
./rollout.sh
```

The rollout commits a file to the default branch, and that push is itself a trigger, so the
first backup starts on its own.

```bash
gh run watch --repo 3d-print-store/documentation
aws s3 ls --recursive s3://git-projects-backups/3d-print-store/
```

You should see one object under `3d-print-store/documentation/main/`.

If the run fails, check the job log first:

| Symptom | Cause |
|---|---|
| `AccessDenied` on upload | IAM policy ARN or bucket name mismatch in step 1.4 |
| A redirect or region error | `aws-region` in step 2.1 does not match the bucket |
| `workflow was not found` | The `v1` tag was never pushed, or the repo is private |
| `Secret AWS_ACCESS_KEY_ID is required` | The rollout could not set secrets on that repo |

---

## Phase 5: roll out to everything

```bash
mv repos.full.txt repos.txt
./rollout.sh
```

Watch the output for `SKIP` and `FAILED` lines. Then confirm the spread:

```bash
aws s3 ls --recursive s3://git-projects-backups/ | awk '{print $4}' | cut -d/ -f1-2 | sort -u
```

Only repos whose default branch received the rollout commit appear immediately. The rest
show up as people push to them.

---

## Ongoing

### Change the workflow for all repos at once

Edit it in the central repo, then move the tag. The sixteen callers pick it up on their next push,
and you never touch them again.

```bash
git commit -am "..." && git push
git tag -f v1 && git push -f origin v1
```

### Add a new repo

Append `owner/repo` to `repos.txt` and re-run `./rollout.sh`. It is safe to
re-run across the whole list, since existing files are updated in place rather than duplicated.

### Rotate the AWS key

Create a new access key, export both variables, re-run `./rollout.sh`,
then delete the old key with `aws iam delete-access-key`.

## Known gaps

- The AWS key lives in all sixteen repos. Anyone with write access to any of them can read it
  out through a workflow. This is the cost of the access-key approach; OIDC removes it.
- Tag pushes are not backed up, only branches.
- Nothing dedupes. Ten pushes to a branch in an hour produce ten near-identical zips.
- Deleting a branch leaves its zips in place until the lifecycle rule expires them.
