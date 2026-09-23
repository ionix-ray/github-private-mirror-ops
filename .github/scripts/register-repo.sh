#!/usr/bin/env bash
# register-repo.sh
# Env: UPSTREAM_FULL, PRIVATE_FULL, BRANCH, GH_TOKEN, GITHUB_REPOSITORY
#
# Adds ONE intent record at tracker/registry/<key>.json and opens a PR.
#
# Conflict-free by construction:
#   * Registration only CREATES a new file (a brand-new path), so two open
#     registration PRs can never collide, and the daily metadata refresh — which
#     writes only tracker/metadata/* — can never collide with this PR either.
#   * No metadata is written here. Observed state (stars/license/etc.) is filled
#     in by the bot's next sync run AFTER merge, into tracker/metadata/<key>.json.
#   * Refuses to add a duplicate (matched on upstream OR private).

set -euo pipefail

: "${UPSTREAM_FULL:?}"
: "${PRIVATE_FULL:?}"
: "${BRANCH:?}"
: "${GH_TOKEN:?}"
: "${GITHUB_REPOSITORY:?}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$SCRIPT_DIR/lib-tracker.sh"
# shellcheck source=/dev/null
. "$SCRIPT_DIR/lib-gh.sh"

# --- Charset hardening (defense-in-depth; upstream caller already validates) ---
is_full_repo  "$UPSTREAM_FULL"     || { echo "::error::UPSTREAM_FULL invalid"; exit 1; }
is_full_repo  "$PRIVATE_FULL"      || { echo "::error::PRIVATE_FULL invalid"; exit 1; }
is_full_repo  "$GITHUB_REPOSITORY" || { echo "::error::GITHUB_REPOSITORY invalid"; exit 1; }
is_valid_branch "$BRANCH"          || { echo "::error::BRANCH invalid: $BRANCH"; exit 1; }

mkdir -p "$REG_DIR" "$META_DIR"

# --- Duplicate detection across existing intent records (jq, no shell interpolation) ---
dup=0
while IFS= read -r f; do
  [[ -z "$f" ]] && continue
  if UP="$UPSTREAM_FULL" PR="$PRIVATE_FULL" jq -e \
      --arg up "$UPSTREAM_FULL" --arg pr "$PRIVATE_FULL" \
      'select(.upstream == $up or .private == $pr)' "$f" >/dev/null; then
    echo "::warning::already registered in $(basename "$f") — skip PR"
    dup=1
  fi
done < <(list_registry_files)
(( dup )) && exit 0

key="$(tracker_key "$PRIVATE_FULL")"
dest="$REG_DIR/$key.json"
if [[ -e "$dest" ]]; then
  echo "::warning::intent file $dest already exists — skip PR"
  exit 0
fi

# Build the intent record (jq --arg is injection-safe), write deterministically.
jq -nc \
  --arg up "$UPSTREAM_FULL" \
  --arg pr "$PRIVATE_FULL" \
  --arg br "$BRANCH" \
  '{upstream:$up, private:$pr, branch:$br, paused:false, pause_reason:""}' \
  | write_json_stable "$dest"
echo "wrote intent record $dest"

# --- Open PR (per-command git -c; no global config writes) ---
GIT_AUTHOR="${GIT_AUTHOR_NAME:-git-private-repo-manager}"
GIT_EMAIL="${GIT_AUTHOR_EMAIL:-bot@dpost.me}"
if [[ "$GIT_AUTHOR" =~ [[:cntrl:]] ]] || [[ "$GIT_EMAIL" =~ [[:cntrl:]] ]]; then
  echo "::error::GIT_AUTHOR_NAME / GIT_AUTHOR_EMAIL contains control characters"; exit 1
fi
if ! [[ "$GIT_EMAIL" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]]; then
  echo "::error::GIT_AUTHOR_EMAIL not a valid email: $GIT_EMAIL"; exit 1
fi

# Shared hardening helpers (same code path as create/sync).
git_setup_auth "register"

# Create the PR branch from the CURRENT base branch (not from any leftover
# register branch), so sequential bulk-import registrations never stack.
base_branch="${BASE_BRANCH:-main}"
branch_name="register/${PRIVATE_FULL//\//-}-$(date -u +%Y%m%d%H%M%S)"
git checkout -b "$branch_name" "origin/$base_branch" 2>/dev/null \
  || git checkout -b "$branch_name" "$base_branch" 2>/dev/null \
  || git checkout -b "$branch_name"

git add "$dest"
git \
  -c "user.email=$GIT_EMAIL" \
  -c "user.name=$GIT_AUTHOR" \
  commit -m "register: $UPSTREAM_FULL -> $PRIVATE_FULL ($BRANCH)" \
  || { echo "nothing to commit"; exit 0; }

git push "https://github.com/${GITHUB_REPOSITORY}.git" "$branch_name"

body="$(printf 'Auto-registered by `new-private-fork.yml` run.\n\n- Upstream: `%s`\n- Private:  `%s`\n- Branch:   `%s`\n- Intent record: `%s`\n\nAdds a single new file — cannot conflict with other registrations or the daily metadata refresh. Merge to enable daily sync (06:00 UTC); the next sync run fills in `tracker/metadata/%s.json`.' \
  "$UPSTREAM_FULL" "$PRIVATE_FULL" "$BRANCH" "$dest" "$key")"

if pr_url="$(gh_open_pr "$GITHUB_REPOSITORY" "register: $UPSTREAM_FULL" "$branch_name" "$body")"; then
  echo "PR opened on branch $branch_name: $pr_url"
else
  echo "::warning::PR creation failed for $branch_name (branch is pushed; open the PR manually if needed)"
fi
