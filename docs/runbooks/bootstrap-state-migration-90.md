# Runbook — migrate legacy bootstrap state into per-account workspaces (#90)

**Status:** one-time, operator-attended. Run once, then delete nothing — the guard
in the `Makefile` (`BOOTSTRAP_MIGRATION_GUARD`) keeps `make bootstrap` / `make
regenerate-backend` blocked until this runbook completes.

**Who runs it:** Bin (operator), on the laptop that holds the local bootstrap
state. Not CI — there is no CI plan/apply lane for `envs/bootstrap`.

**Blast radius:** local files only. This migration performs **no** state-mutating
Terraform command and **no** `terraform apply`. The only AWS call is a read-only
`terraform plan` (refresh) used to prove each migrated state matches reality.
Nothing in AWS changes. Rollback is pure local-file restoration.

---

## 1. Why this migration exists

PR #139 (`fix(bootstrap): per-account state via workspaces (#90)`) moved the
bootstrap env to a Terraform **workspace per account**: each account's local state
now lives at `terraform/envs/bootstrap/terraform.tfstate.d/<ENV>/terraform.tfstate`.
The `Makefile` runs `terraform workspace select -or-create <ENV>` on every
bootstrap / backend-regenerate.

PR #139 shipped the **code**. It did **not** move the state that already existed on
the operator laptop from before #139. That legacy state is still in the
pre-workspace layout:

| Legacy file (pre-#90) | Holds account | Bucket | Target workspace |
|---|---|---|---|
| `terraform/envs/bootstrap/terraform.tfstate` (default workspace) | prod `506221082337` | `aegis-platform-aws-tfstate-506221082337` | `prod` |
| `terraform/envs/bootstrap/terraform.tfstate.staging` (old `-state=` juggle file) | staging `251774439261` | `aegis-platform-aws-tfstate-251774439261` | `staging` |

Both are gitignored (never committed). Until they are moved into the workspace
layout, running `make bootstrap ENV=prod` would select an **empty** `prod`
workspace, orphan the real prod state in the default workspace, and the follow-on
`terraform apply` would try to **re-create** the `prevent_destroy` state bucket and
fail. The `BOOTSTRAP_MIGRATION_GUARD` blocks that path until this runbook is done.

> Account IDs above are the values already committed throughout this repo
> (`variables.tf`, `iam-seed-import.tf`, `README.md`). A forker substitutes their
> own account IDs; the procedure is identical.

## 2. Preconditions — check first

Run from the repo root of `aegis-platform-aws` on `main` (with this PR merged).

```bash
cd ~/Documents/aegis-platform-aws/terraform/envs/bootstrap

# 2a. Both legacy state files exist and are non-empty.
ls -l terraform.tfstate terraform.tfstate.staging

# 2b. Confirm which account each holds (must match the table in §1).
grep -o 'aegis-platform-aws-tfstate-[0-9]\{12\}' terraform.tfstate        | sort -u   # -> ...-506221082337 (prod)
grep -o 'aegis-platform-aws-tfstate-[0-9]\{12\}' terraform.tfstate.staging | sort -u  # -> ...-251774439261 (staging)

# 2c. The workspace layout does NOT exist yet (nothing to overwrite).
test ! -d terraform.tfstate.d && echo "OK: no workspace dir yet" || echo "STOP: terraform.tfstate.d already exists — inspect before proceeding"

# 2d. Terraform version supports workspaces + native S3 locking (>= 1.11).
terraform version
```

If 2b shows an account you did not expect, **STOP** — do not migrate a state file
into the wrong workspace. If 2c reports the dir already exists, some earlier partial
run created it; inspect `terraform.tfstate.d/` contents before continuing.

## 3. Back up (rollback anchor)

```bash
BK=~/aegis-bootstrap-state-backup-$(date +%Y%m%d-%H%M%S)
mkdir -p "$BK"
cp -p terraform.tfstate terraform.tfstate.backup \
      terraform.tfstate.staging terraform.tfstate.staging.backup "$BK"/ 2>/dev/null
ls -l "$BK"
echo "BACKUP DIR = $BK   # record this; rollback restores from here"
```

Keep `$BK` until §6 verification is green on both accounts.

## 4. Create the workspaces and place the state (offline file copy)

`terraform workspace new` creates the workspace directory with an **empty** state
and switches to it; we then overwrite that empty file with the legacy state. For a
**local** backend this is a plain file replacement — Terraform reads whatever file
is present on the next command. No lineage/serial force flags, no AWS calls.

```bash
# still in terraform/envs/bootstrap
terraform init          # local backend; ensures providers present, moves no state

# prod: default-workspace legacy state -> prod workspace
terraform workspace new prod
cp terraform.tfstate terraform.tfstate.d/prod/terraform.tfstate

# staging: old -state= juggle file -> staging workspace
terraform workspace new staging
cp terraform.tfstate.staging terraform.tfstate.d/staging/terraform.tfstate

terraform workspace list    # expect: default, prod, staging  (* on staging)
```

> Alternative (`terraform state push`) is **not** recommended here: pushing a
> legacy state whose lineage differs from the freshly-created empty workspace state
> requires `-force`, which disables every safety check. The file copy above is
> simpler and safer for local state.

## 5. Verify each workspace against reality (read-only)

For each account, select its workspace, confirm state contents offline, then run a
**read-only** `terraform plan`. A clean migration shows **no changes** — the state
already describes the live bucket + CI roles.

`terraform plan` needs the account's AWS credentials and the bootstrap variables
(`github_owner`, the three `github_*_repo_id` values, `platform_region`) supplied
via the repo-root `regions.auto.tfvars.json`. Use the **same operator / break-glass
principal** you bootstrap with (`AWSControlTowerExecution` — SSO principals are
denied IAM by the org SCP).

```bash
VARFILE=../../../regions.auto.tfvars.json

# --- prod ---
# (assume prod break-glass credentials in the shell, e.g. via aws sso / assume-role)
terraform workspace select prod
terraform workspace show                 # -> prod
terraform state list                     # -> aws_s3_bucket.tfstate + versioning/sse/pab + 5 iam roles, etc.
terraform plan -var-file="$VARFILE"      # EXPECT: "No changes. Your infrastructure matches the configuration."

# --- staging ---
# (swap to staging break-glass credentials)
terraform workspace select staging
terraform workspace show                 # -> staging
terraform state list
terraform plan -var-file="$VARFILE"      # EXPECT: "No changes."
```

**Decision gate:**
- Plan says **No changes** → state matches reality → migration for that account is correct. Continue.
- Plan wants to **create** `aws_s3_bucket.tfstate` (or the CI roles) → the workspace
  loaded an empty/wrong state → **STOP**, go to §7 rollback, re-check §2b.
- Plan wants small in-place **updates** (e.g. a tag or trust-policy drift from a newer
  commit) → that is real config drift, not a migration failure. Note it; it will be
  reconciled by the normal `make bootstrap ENV=<env>` apply **after** this migration.
  Do not treat it as a migration error.

## 6. Retire the legacy files (clears the guard)

Only after **both** plans are clean (§5), move the legacy files out of the working
tree so the default workspace can no longer shadow the migrated state. This is the
step that satisfies `BOOTSTRAP_MIGRATION_GUARD`.

```bash
mv terraform.tfstate terraform.tfstate.backup \
   terraform.tfstate.staging terraform.tfstate.staging.backup "$BK"/legacy-retired/ 2>/dev/null || \
   { mkdir -p "$BK"/legacy-retired && mv terraform.tfstate terraform.tfstate.backup \
     terraform.tfstate.staging terraform.tfstate.staging.backup "$BK"/legacy-retired/ 2>/dev/null; }
ls terraform.tfstate* 2>/dev/null && echo "WARN: legacy files still present" || echo "OK: legacy default/juggle state retired"
```

Then confirm the Makefile path is unblocked end-to-end (read-only — regenerates the
gitignored `backend.hcl` from the migrated workspace output):

```bash
cd ~/Documents/aegis-platform-aws
make regenerate-backend ENV=prod       # selects prod workspace, writes ./backend.hcl
make regenerate-backend ENV=staging    # selects staging workspace
make -n bootstrap ENV=prod             # dry run: guard no longer fires (prod workspace now exists)
```

Migration is complete when `make regenerate-backend ENV=<env>` succeeds for both
accounts and `make -n bootstrap ENV=prod` shows the guard passing.

## 7. Rollback

No AWS state was mutated, so rollback is local-file only.

- **Before §6** (legacy files still in place): discard the new workspaces and you are
  back to the pre-migration layout.
  ```bash
  cd ~/Documents/aegis-platform-aws/terraform/envs/bootstrap
  terraform workspace select default
  rm -rf terraform.tfstate.d
  ```
- **After §6** (legacy files retired): restore them from the backup, then discard the
  workspaces.
  ```bash
  cd ~/Documents/aegis-platform-aws/terraform/envs/bootstrap
  cp -p "$BK"/legacy-retired/terraform.tfstate         terraform.tfstate
  cp -p "$BK"/legacy-retired/terraform.tfstate.staging terraform.tfstate.staging
  terraform workspace select default
  rm -rf terraform.tfstate.d
  ```
- If a state file was ever overwritten by accident, the pristine copies are in `$BK`
  (the §3 backup) and `$BK/legacy-retired`.

## 8. Out of scope (issue #90 residuals — separate work)

Issue #90's "Also:" paragraph lists two items beyond the per-account state model.
Neither is fixed here:

1. **Break-glass S3 grant.** #90 asks to extend the `aegis-emergency-break-glass`
   role's S3 grant to `aegis-platform-aws-tfstate-*`. That role + policy live in
   **`aegis-landing-zone-aws`** (the account-fabric tier), not this repo — a repo-wide
   grep finds no such policy resource here. It is a separate LDZ PR. See how LDZ
   scoped per-account state access in its PR #322 (per-account key-prefix bucket
   policy) for the pattern that grant should follow.
2. **Surviving-bucket import on a fresh local state.** The CI IAM roles already have a
   toggleable survivor-adoption path (`iam-seed-import.tf`, `var.adopt_seeded_iam_roles`).
   The state **bucket** has `prevent_destroy` so it outlives a teardown, but there is
   no equivalent `import` block to re-adopt it if the *local state* is lost while the
   bucket persists (cold-start-after-state-loss, distinct from this workspace
   migration). Tracked as a follow-up; not required for the per-account model.
