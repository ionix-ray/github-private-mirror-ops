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
UPSTREAM_FULL="${up_owner}/${up_repo}"

# --- Fetch upstream metadata (must be public + not archived) ---
http=$(curl -sS -o /tmp/up.json -w '%{http_code}' \
  -H "Accept: application/vnd.github+json" \
  -H "Authorization: Bearer ${GH_TOKEN}" \
  -H "X-GitHub-Api-Version: 2022-11-28" \
  "https://api.github.com/repos/${UPSTREAM_FULL}")
if [[ "$http" != "200" ]]; then
  echo "::error::upstream '$UPSTREAM_FULL' not reachable (HTTP $http)"
  exit 1
fi
visibility=$(jq -r '.visibility // (.private | if . then "private" else "public" end)' /tmp/up.json)
if [[ "$visibility" != "public" ]]; then
  echo "::error::upstream '$UPSTREAM_FULL' is not public (visibility=$visibility)"
  exit 1
fi
default_branch=$(jq -r '.default_branch' /tmp/up.json)
upstream_size_kb=$(jq -r '.size // 0' /tmp/up.json)
description=$(jq -r '.description // ""' /tmp/up.json)

# Refuse repos > 5 GB to keep runner safe
if (( upstream_size_kb > 5 * 1024 * 1024 )); then
  echo "::error::upstream is ${upstream_size_kb} KB — exceeds 5GB runner safety cap"
  exit 1
fi

# --- Resolve branch ---
if [[ -z "${BRANCH_INPUT:-}" ]]; then
  BRANCH="$default_branch"
elif [[ "$BRANCH_INPUT" == "all" ]]; then
  BRANCH="all"
else
  # confirm branch exists on upstream
  bhttp=$(curl -sS -o /dev/null -w '%{http_code}' \
    -H "Accept: application/vnd.github+json" \
    -H "Authorization: Bearer ${GH_TOKEN}" \
    "https://api.github.com/repos/${UPSTREAM_FULL}/branches/${BRANCH_INPUT}")
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
existing_http=$(curl -sS -o /dev/null -w '%{http_code}' \
  -H "Accept: application/vnd.github+json" \
  -H "Authorization: Bearer ${GH_TOKEN}" \
  "https://api.github.com/repos/${PRIVATE_FULL}")
if [[ "$existing_http" == "200" ]]; then
  echo "::error::private repo '$PRIVATE_FULL' already exists — refusing to overwrite. Pick a different private_name or delete it first."
  exit 1
fi

# --- Mirror clone ---
workdir="$(mktemp -d)"
trap 'rm -rf "$workdir"' EXIT
cd "$workdir"

clone_url="https://github.com/${UPSTREAM_FULL}.git"
echo "Cloning $clone_url ..."
if [[ "$BRANCH" == "all" ]]; then
  git clone --mirror --no-tags "$clone_url" mirror.git
else
  # mirror clone restricted to single branch via refspec
  git clone --bare --single-branch --branch "$BRANCH" --no-tags "$clone_url" mirror.git
fi
cd mirror.git

# --- Create private repo ---
echo "Creating private repo ${PRIVATE_FULL} ..."
# Determine if target_owner is user or org for the create endpoint
otype=$(jq -r '.type' /tmp/owner.json 2>/dev/null || echo "")
if [[ -z "$otype" ]]; then
  ohttp=$(curl -sS -o /tmp/owner.json -w '%{http_code}' \
    -H "Authorization: Bearer ${GH_TOKEN}" \
    "https://api.github.com/users/${TARGET_OWNER}")
  [[ "$ohttp" == "200" ]] || { echo "::error::target owner lookup failed"; exit 1; }
  otype=$(jq -r '.type' /tmp/owner.json)
fi

desc=$(jq -nc --arg d "Mirror of https://github.com/${UPSTREAM_FULL}" --arg n "$PRIVATE_NAME" \
  '{name:$n, description:$d, private:true, has_issues:true, has_projects:false, has_wiki:false, auto_init:false}')

if [[ "$otype" == "Organization" ]]; then
  create_url="https://api.github.com/orgs/${TARGET_OWNER}/repos"
else
  create_url="https://api.github.com/user/repos"
fi

chttp=$(curl -sS -o /tmp/create.json -w '%{http_code}' -X POST \
  -H "Accept: application/vnd.github+json" \
  -H "Authorization: Bearer ${GH_TOKEN}" \
  -H "X-GitHub-Api-Version: 2022-11-28" \
  -d "$desc" "$create_url")
if [[ "$chttp" != "201" ]]; then
  echo "::error::create private repo failed (HTTP $chttp): $(jq -r '.message // .' /tmp/create.json)"
  exit 1
fi

# --- Push ---
push_url="https://x-access-token:${GH_TOKEN}@github.com/${PRIVATE_FULL}.git"
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
  curl -sS -X DELETE \
    -H "Authorization: Bearer ${GH_TOKEN}" \
    "https://api.github.com/repos/${PRIVATE_FULL}" || true
  exit 1
fi

# --- Set default branch on private to match ---
db="$BRANCH"
[[ "$BRANCH" == "all" ]] && db="$default_branch"
curl -sS -X PATCH -o /dev/null \
  -H "Accept: application/vnd.github+json" \
  -H "Authorization: Bearer ${GH_TOKEN}" \
  -d "$(jq -nc --arg b "$db" '{default_branch:$b}')" \
  "https://api.github.com/repos/${PRIVATE_FULL}" || true

# --- Outputs ---
{
  echo "upstream_full=${UPSTREAM_FULL}"
  echo "private_full=${PRIVATE_FULL}"
  echo "branch=${BRANCH}"
} >> "$GITHUB_OUTPUT"

echo "OK: mirrored ${UPSTREAM_FULL} -> ${PRIVATE_FULL} (branch=${BRANCH})"
