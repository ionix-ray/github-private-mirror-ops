#!/usr/bin/env bash
# mirror-clone-push.sh
# Reads env: PUBLIC_URL, TARGET_OWNER, BRANCH_INPUT, PRIVATE_NAME_INPUT, GH_TOKEN
# Outputs to $GITHUB_OUTPUT: upstream_full, private_full, branch
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

# --- Hardening helpers ---
# Per-run tempdir; auto-cleanup on exit. Avoids /tmp TOCTOU.
TMPDIR_RUN="$(mktemp -d -t mirror.XXXXXXXX)"
trap 'rm -rf "$TMPDIR_RUN"' EXIT

# GIT_ASKPASS shim so the PAT never appears in argv or remote URLs.
ASKPASS="$TMPDIR_RUN/askpass.sh"
make_askpass "$ASKPASS"
export GIT_ASKPASS="$ASKPASS"
export GIT_TERMINAL_PROMPT=0

# --- Parse URL into owner/repo ---
url="${PUBLIC_URL%.git}"
url="${url%/}"
case "$url" in
  https://github.com/*) ;;
  http://github.com/*)  ;;
  git@github.com:*)
    url="https://github.com/${url#git@github.com:}" ;;
  *)
    echo "::error::only github.com URLs supported, got: $PUBLIC_URL"
    exit 1
    ;;
esac
path="${url#https://github.com/}"
path="${path#http://github.com/}"
up_owner="${path%%/*}"
up_repo="${path#*/}"
up_repo="${up_repo%%/*}"

if [[ -z "$up_owner" || -z "$up_repo" || "$up_owner" == "$up_repo" ]]; then
  echo "::error::could not parse owner/repo from: $PUBLIC_URL"
  exit 1
fi
if ! is_valid_owner_or_repo "$up_owner" || ! is_valid_owner_or_repo "$up_repo"; then
  echo "::error::upstream owner/repo contains unsupported characters"
  exit 1
fi
if ! is_valid_owner_or_repo "$TARGET_OWNER"; then
  echo "::error::TARGET_OWNER contains unsupported characters"
  exit 1
fi
UPSTREAM_FULL="${up_owner}/${up_repo}"

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

# --- Mirror clone ---
workdir="$TMPDIR_RUN/work"
mkdir -p "$workdir"
cd "$workdir"

clone_url="https://github.com/${UPSTREAM_FULL}.git"
echo "Cloning $clone_url ..."
if [[ "$BRANCH" == "all" ]]; then
  git clone --mirror --no-tags "$clone_url" mirror.git
else
  # bare clone restricted to single branch
  git clone --bare --single-branch --branch "$BRANCH" --no-tags "$clone_url" mirror.git
fi
cd mirror.git

# --- Create private repo ---
echo "Creating private repo ${PRIVATE_FULL} ..."
OWNER_JSON="$TMPDIR_RUN/owner.json"
ohttp="$(gh_api GET "https://api.github.com/users/${TARGET_OWNER}" "$OWNER_JSON")"
[[ "$ohttp" == "200" ]] || { echo "::error::target owner lookup failed (HTTP $ohttp)"; exit 1; }
otype=$(jq -r '.type' "$OWNER_JSON")

desc=$(jq -nc --arg d "Mirror of https://github.com/${UPSTREAM_FULL}" --arg n "$PRIVATE_NAME" \
  '{name:$n, description:$d, private:true, has_issues:true, has_projects:false, has_wiki:false, auto_init:false}')

if [[ "$otype" == "Organization" ]]; then
  create_url="https://api.github.com/orgs/${TARGET_OWNER}/repos"
else
  create_url="https://api.github.com/user/repos"
fi

CREATE_JSON="$TMPDIR_RUN/create.json"
chttp="$(curl -sS -o "$CREATE_JSON" -w '%{http_code}' -X POST \
  -H "Accept: application/vnd.github+json" \
  -H "Authorization: Bearer ${GH_TOKEN}" \
  -H "X-GitHub-Api-Version: 2022-11-28" \
  -d "$desc" "$create_url")"
if [[ "$chttp" != "201" ]]; then
  echo "::error::create private repo failed (HTTP $chttp): $(jq -r '.message // .' "$CREATE_JSON")"
  exit 1
fi

# --- Push (token via GIT_ASKPASS, never in URL/argv) ---
push_url="https://github.com/${PRIVATE_FULL}.git"
echo "Pushing to ${PRIVATE_FULL} ..."
push_failed=0
if [[ "$BRANCH" == "all" ]]; then
  git push --mirror "$push_url" || push_failed=1
else
  # push only the single branch we cloned, preserve branch name
  git push "$push_url" "refs/heads/${BRANCH}:refs/heads/${BRANCH}" || push_failed=1
fi

if (( push_failed )); then
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
patch_http="$(curl -sS -o /dev/null -w '%{http_code}' -X PATCH \
  -H "Accept: application/vnd.github+json" \
  -H "Authorization: Bearer ${GH_TOKEN}" \
  -H "X-GitHub-Api-Version: 2022-11-28" \
  -d "$(jq -nc --arg b "$db" '{default_branch:$b}')" \
  "https://api.github.com/repos/${PRIVATE_FULL}")"
if [[ "$patch_http" != "200" ]]; then
  echo "::warning::failed to set default_branch on $PRIVATE_FULL (HTTP $patch_http) — verify manually"
fi

# --- Outputs ---
{
  echo "upstream_full=${UPSTREAM_FULL}"
  echo "private_full=${PRIVATE_FULL}"
  echo "branch=${BRANCH}"
} >> "$GITHUB_OUTPUT"

echo "OK: mirrored ${UPSTREAM_FULL} -> ${PRIVATE_FULL} (branch=${BRANCH})"
