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

dup_up=$(yq -r ".repos | map(select(.upstream == \"$UPSTREAM_FULL\")) | length" "$REG")
dup_pr=$(yq -r ".repos | map(select(.private  == \"$PRIVATE_FULL\"))  | length" "$REG")
if [[ "$dup_up" != "0" || "$dup_pr" != "0" ]]; then
  echo "::warning::already registered (upstream dup=$dup_up, private dup=$dup_pr) — skip PR"
  exit 0
fi

new=$(yq -n \
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

# append entry
echo "$new" > /tmp/new.yml
yq -i ".repos += [load(\"/tmp/new.yml\")]" "$REG"

# capture license + metadata into the new entry
bash .github/scripts/capture-license.sh "$UPSTREAM_FULL" || true

# Open PR
git config user.email "mirror-ops-bot@users.noreply.github.com"
git config user.name  "mirror-ops-bot"

branch_name="register/${UPSTREAM_FULL//\//-}-$(date -u +%Y%m%d%H%M%S)"
git checkout -b "$branch_name"
git add "$REG"
git commit -m "register: $UPSTREAM_FULL -> $PRIVATE_FULL ($BRANCH)" || { echo "nothing to commit"; exit 0; }

# Use the same PAT for push
remote_url="https://x-access-token:${GH_TOKEN}@github.com/${GITHUB_REPOSITORY}.git"
git push "$remote_url" "$branch_name"

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

curl -sS -X POST -o /tmp/pr.json -w '\nHTTP %{http_code}\n' \
  -H "Accept: application/vnd.github+json" \
  -H "Authorization: Bearer ${GH_TOKEN}" \
  -H "X-GitHub-Api-Version: 2022-11-28" \
  -d "$pr_body" \
  "https://api.github.com/repos/${GITHUB_REPOSITORY}/pulls"

echo "PR opened on branch $branch_name"
