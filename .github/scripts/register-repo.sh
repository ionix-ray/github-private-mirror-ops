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
is_valid_branch(){ [[ "$1" =~ ^[A-Za-z0-9._/-]{1,200}$ && "$1" != *".."* && "$1" != /* && "$1" != */ ]] || [[ "$1" == "all" ]]; }

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

TMPDIR_RUN="$(mktemp -d -t register.XXXXXXXX)"
trap 'rm -rf "$TMPDIR_RUN"' EXIT

# GIT_ASKPASS shim: PAT never in argv/URL.
ASKPASS="$TMPDIR_RUN/askpass.sh"
make_askpass "$ASKPASS"
export GIT_ASKPASS="$ASKPASS"
export GIT_TERMINAL_PROMPT=0

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

body=$(cat <<EOF
Auto-registered by \`new-private-fork.yml\` run.

- Upstream: \`$UPSTREAM_FULL\`
- Private:  \`$PRIVATE_FULL\`
- Branch:   \`$BRANCH\`
- Intent record: \`$dest\`

Adds a single new file — cannot conflict with other registrations or the daily
metadata refresh. Merge to enable daily sync (06:00 UTC); the next sync run fills
in \`tracker/metadata/$key.json\`.
EOF
)

pr_body=$(jq -nc --arg t "register: $UPSTREAM_FULL" --arg h "$branch_name" --arg b "$body" \
  '{title:$t, head:$h, base:"main", body:$b}')

PR_JSON="$TMPDIR_RUN/pr.json"
pr_http="$(curl -sS -X POST -o "$PR_JSON" -w '%{http_code}' \
  -H "Accept: application/vnd.github+json" \
  -H "Authorization: Bearer ${GH_TOKEN}" \
  -H "X-GitHub-Api-Version: 2022-11-28" \
  -d "$pr_body" \
  "https://api.github.com/repos/${GITHUB_REPOSITORY}/pulls")"
if [[ "$pr_http" != "201" ]]; then
  echo "::warning::PR creation returned HTTP $pr_http: $(jq -r '.message // .' "$PR_JSON" 2>/dev/null || true)"
fi

echo "PR opened on branch $branch_name"
