#!/usr/bin/env bash
# register-repo.sh
# Env: UPSTREAM_FULL, PRIVATE_FULL, BRANCH, GH_TOKEN, GITHUB_REPOSITORY
# Adds an entry to .github/synced-repos.yml and opens a PR against the ops repo.
# Refuses to add a duplicate (matched on upstream OR private).

set -euo pipefail

: "${UPSTREAM_FULL:?}"
: "${PRIVATE_FULL:?}"
: "${BRANCH:?}"
: "${GH_TOKEN:?}"
: "${GITHUB_REPOSITORY:?}"

REG=".github/synced-repos.yml"

# --- Charset hardening (defense-in-depth; upstream caller already validates) ---
is_full_repo()   { [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*/[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; }
is_valid_branch(){ [[ "$1" =~ ^[A-Za-z0-9._/-]{1,200}$ && "$1" != *".."* && "$1" != /* && "$1" != */ ]] || [[ "$1" == "all" ]]; }

is_full_repo  "$UPSTREAM_FULL"     || { echo "::error::UPSTREAM_FULL invalid"; exit 1; }
is_full_repo  "$PRIVATE_FULL"      || { echo "::error::PRIVATE_FULL invalid"; exit 1; }
is_full_repo  "$GITHUB_REPOSITORY" || { echo "::error::GITHUB_REPOSITORY invalid"; exit 1; }
is_valid_branch "$BRANCH"          || { echo "::error::BRANCH invalid: $BRANCH"; exit 1; }

# --- Per-run tempdir + cleanup ---
TMPDIR_RUN="$(mktemp -d -t register.XXXXXXXX)"
trap 'rm -rf "$TMPDIR_RUN"' EXIT

# --- GIT_ASKPASS shim: PAT never in argv/URL ---
ASKPASS="$TMPDIR_RUN/askpass.sh"
cat >"$ASKPASS" <<'EOS'
#!/usr/bin/env bash
case "$1" in
  Username*) echo "x-access-token" ;;
  Password*) echo "${GH_TOKEN:-}" ;;
esac
EOS
chmod 0700 "$ASKPASS"
export GIT_ASKPASS="$ASKPASS"
export GIT_TERMINAL_PROMPT=0

# --- Duplicate detection (yq env() to block injection) ---
dup_up=$(UP="$UPSTREAM_FULL" yq -r '.repos | map(select(.upstream == strenv(UP))) | length' "$REG")
dup_pr=$(PR="$PRIVATE_FULL"  yq -r '.repos | map(select(.private  == strenv(PR))) | length' "$REG")
if [[ "$dup_up" != "0" || "$dup_pr" != "0" ]]; then
  echo "::warning::already registered (upstream dup=$dup_up, private dup=$dup_pr) — skip PR"
  exit 0
fi

# Build the new entry as JSON with jq (which supports --arg safely);
# mikefarah/yq's load() auto-detects YAML/JSON, so the file can be loaded directly.
new=$(jq -nc \
  --arg up "$UPSTREAM_FULL" \
  --arg pr "$PRIVATE_FULL" \
  --arg br "$BRANCH" \
  '{
    upstream: $up,
    private:  $pr,
    branch:   $br,
    paused:   false,
    pause_reason: "",
    last_synced_sha: "",
    last_synced_at:  "",
    last_synced_status: "",
    last_upstream_sha: "",
    last_validated_at: "",
    upstream_default_branch: "",
    upstream_archived: false,
    upstream_pushed_at: "",
    upstream_size_kb: 0,
    license_current_spdx: "",
    license_current_name: "",
    license_history: []
  }')

# Append entry via env(NEWPATH) — no shell interpolation in yq expression
NEWFILE="$TMPDIR_RUN/new.json"
printf '%s\n' "$new" > "$NEWFILE"
NEWPATH="$NEWFILE" yq -i '.repos += [load(env(NEWPATH))]' "$REG"

# Capture license + metadata into the new entry
bash .github/scripts/capture-license.sh "$UPSTREAM_FULL" || true

# --- Open PR (per-command git -c; no global config writes) ---
# Author identity injected from pipeline env; fall back to project defaults.
GIT_AUTHOR="${GIT_AUTHOR_NAME:-git-private-repo-manager}"
GIT_EMAIL="${GIT_AUTHOR_EMAIL:-bot@dpost.me}"

# Validate identity strings (no newlines/control chars that could break git config).
if [[ "$GIT_AUTHOR" =~ [[:cntrl:]] ]] || [[ "$GIT_EMAIL" =~ [[:cntrl:]] ]]; then
  echo "::error::GIT_AUTHOR_NAME / GIT_AUTHOR_EMAIL contains control characters"
  exit 1
fi
if ! [[ "$GIT_EMAIL" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]]; then
  echo "::error::GIT_AUTHOR_EMAIL not a valid email: $GIT_EMAIL"
  exit 1
fi

branch_name="register/${UPSTREAM_FULL//\//-}-$(date -u +%Y%m%d%H%M%S)"
git checkout -b "$branch_name"
git add "$REG"
git \
  -c "user.email=$GIT_EMAIL" \
  -c "user.name=$GIT_AUTHOR" \
  commit -m "register: $UPSTREAM_FULL -> $PRIVATE_FULL ($BRANCH)" \
  || { echo "nothing to commit"; exit 0; }

# Push via askpass — token not in URL
git push "https://github.com/${GITHUB_REPOSITORY}.git" "$branch_name"

body=$(cat <<EOF
Auto-registered by \`new-private-fork.yml\` run.

- Upstream: \`$UPSTREAM_FULL\`
- Private:  \`$PRIVATE_FULL\`
- Branch:   \`$BRANCH\`

Merge to enable daily sync (06:00 UTC).
EOF
)

pr_body=$(jq -nc --arg t "register: $UPSTREAM_FULL" --arg h "$branch_name" --arg b "$body" \
  '{title:$t, head:$h, base:"main", body:$b}')

PR_JSON="$TMPDIR_RUN/pr.json"
pr_http=$(curl -sS -X POST -o "$PR_JSON" -w '%{http_code}' \
  -H "Accept: application/vnd.github+json" \
  -H "Authorization: Bearer ${GH_TOKEN}" \
  -H "X-GitHub-Api-Version: 2022-11-28" \
  -d "$pr_body" \
  "https://api.github.com/repos/${GITHUB_REPOSITORY}/pulls")
if [[ "$pr_http" != "201" ]]; then
  echo "::warning::PR creation returned HTTP $pr_http: $(jq -r '.message // .' "$PR_JSON" 2>/dev/null || true)"
fi

echo "PR opened on branch $branch_name"
