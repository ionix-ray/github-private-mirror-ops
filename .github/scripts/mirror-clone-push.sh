#!/usr/bin/env bash
# mirror-clone-push.sh
# Reads env: PUBLIC_URL, TARGET_OWNER, BRANCH_INPUT, PRIVATE_NAME_INPUT, GH_TOKEN
# Outputs to $GITHUB_OUTPUT: upstream_full, private_full, branch
#
# Composes over the shared primitives in lib-gh.sh (git_setup_auth,
# parse_github_url, git_clone_upstream, create_private_repo, git_push_private,
# set_default_branch) so create and sync use the SAME code path.
#
# Idempotent: if private repo already exists, aborts with clear error (no overwrite).
# Cleans up the empty private repo if the push step fails.

set -euo pipefail

: "${PUBLIC_URL:?}"
: "${TARGET_OWNER:?}"
: "${GH_TOKEN:?}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$SCRIPT_DIR/lib-gh.sh"

# --- Hardening helpers (shared, from lib-gh.sh) ---
git_setup_auth "mirror"

# --- Parse URL into owner/repo (shared helper) ---
parsed="$(parse_github_url "$PUBLIC_URL")" || exit 1
up_owner="${parsed%% *}"
up_repo="${parsed#* }"
UPSTREAM_FULL="${up_owner}/${up_repo}"

if ! is_valid_owner_or_repo "$TARGET_OWNER"; then
  echo "::error::TARGET_OWNER contains unsupported characters"
  exit 1
fi

# --- Fetch upstream metadata (must be public + not archived) ---
UP_JSON="$TMPDIR_RUN/up.json"
http="$(gh_api GET "https://api.github.com/repos/${UPSTREAM_FULL}" "$UP_JSON")"
if [[ "$http" != "200" ]]; then
  echo "::error::upstream '$UPSTREAM_FULL' not reachable (HTTP $http)"
  exit 1
fi
visibility=$(jq -r '.visibility // (.private | if . then "private" else "public" end)' "$UP_JSON")
if [[ "$visibility" != "public" ]]; then
  echo "::error::upstream '$UPSTREAM_FULL' is not public (visibility=$visibility)"
  exit 1
fi
default_branch=$(jq -r '.default_branch' "$UP_JSON")
upstream_size_kb=$(jq -r '.size // 0' "$UP_JSON")

# Refuse repos > 5 GB to keep runner safe
if (( upstream_size_kb > 5 * 1024 * 1024 )); then
  echo "::error::upstream is ${upstream_size_kb} KB — exceeds 5GB runner safety cap"
  exit 1
fi

# --- Resolve branch ---
if [[ -z "${BRANCH_INPUT:-}" ]]; then
  if ! is_valid_branch "$default_branch"; then
    echo "::error::upstream default_branch contains unsupported characters: $default_branch"
    exit 1
  fi
  BRANCH="$default_branch"
elif [[ "$BRANCH_INPUT" == "all" ]]; then
  BRANCH="all"
else
  if ! is_valid_branch "$BRANCH_INPUT"; then
    echo "::error::branch input contains unsupported characters: $BRANCH_INPUT"
    exit 1
  fi
  # confirm branch exists on upstream
  bhttp="$(gh_api GET "https://api.github.com/repos/${UPSTREAM_FULL}/branches/${BRANCH_INPUT}" /dev/null)"
  if [[ "$bhttp" != "200" ]]; then
    echo "::error::branch '$BRANCH_INPUT' not found on $UPSTREAM_FULL (HTTP $bhttp)"
    exit 1
  fi
  BRANCH="$BRANCH_INPUT"
fi

# --- Resolve private repo name ---
PRIVATE_NAME="${PRIVATE_NAME_INPUT:-$up_repo}"
# sanitize: allow only [A-Za-z0-9._-]
if [[ ! "$PRIVATE_NAME" =~ ^[A-Za-z0-9._-]+$ ]]; then
  echo "::error::invalid private repo name: $PRIVATE_NAME"
  exit 1
fi
PRIVATE_FULL="${TARGET_OWNER}/${PRIVATE_NAME}"

# --- Idempotency: refuse to overwrite an existing repo ---
existing_http="$(gh_api GET "https://api.github.com/repos/${PRIVATE_FULL}" /dev/null)"
if [[ "$existing_http" == "200" ]]; then
  echo "::error::private repo '$PRIVATE_FULL' already exists — refusing to overwrite. Pick a different private_name or delete it first."
  exit 1
fi

# --- Mirror clone (shared helper) ---
workdir="$TMPDIR_RUN/work"
git_clone_upstream "$UPSTREAM_FULL" "$BRANCH" "$workdir"

# --- Create private repo (shared helper) ---
echo "Creating private repo ${PRIVATE_FULL} ..."
if ! create_private_repo "$TARGET_OWNER" "$PRIVATE_NAME" "$UPSTREAM_FULL"; then
  exit 1
fi

# --- Push (shared helper; token via GIT_ASKPASS, never in URL/argv) ---
if [[ "$BRANCH" == "all" ]]; then
  push_mode="mirror"
else
  push_mode="branch"
fi
if ! git_push_private "$PRIVATE_FULL" "$BRANCH" "$push_mode"; then
  echo "::error::push failed — rolling back created private repo"
  rb_http="$(gh_api DELETE "https://api.github.com/repos/${PRIVATE_FULL}" /dev/null)"
  if [[ "$rb_http" != "204" ]]; then
    echo "::warning::rollback DELETE returned HTTP $rb_http — orphan repo may remain at $PRIVATE_FULL"
  fi
  exit 1
fi

# --- Set default branch on private to match ---
db="$BRANCH"
[[ "$BRANCH" == "all" ]] && db="$default_branch"
set_default_branch "$PRIVATE_FULL" "$db" || true

# --- Outputs ---
{
  echo "upstream_full=${UPSTREAM_FULL}"
  echo "private_full=${PRIVATE_FULL}"
  echo "branch=${BRANCH}"
} >> "$GITHUB_OUTPUT"

echo "OK: mirrored ${UPSTREAM_FULL} -> ${PRIVATE_FULL} (branch=${BRANCH})"
