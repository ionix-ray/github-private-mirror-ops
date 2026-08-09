#!/usr/bin/env bash
# lib-gh.sh — shared GitHub API + hardening helpers for mirror-ops scripts.
# Source from scripts:  . "$(dirname "$0")/lib-gh.sh"
#
# All functions are pure (no global state) except those that export the
# per-run tempdir, so they are unit-testable offline. Keep it dependency-free
# (bash + curl + jq only) so the Actions runners and CI stay light.

set -euo pipefail

#---------------------------------------------------------------------------
# Validation guards (defense-in-depth, offline, injectable)
#---------------------------------------------------------------------------

# is_valid_owner_or_repo NAME -> 0/1
is_valid_owner_or_repo() { [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,99}$ ]]; }

# is_valid_branch BRANCH -> 0/1  (allows '/', forbids path tricks)
is_valid_branch() {
  [[ "$1" =~ ^[A-Za-z0-9._/-]{1,200}$ && "$1" != *".."* && "$1" != /* && "$1" != */ ]]
}

# is_full_repo OWNER/REPO -> 0/1
is_full_repo() { [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*/[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; }

#---------------------------------------------------------------------------
# Token handling
#---------------------------------------------------------------------------

# mask_token — mask + assert GH_TOKEN present. Never echoes the token value.
mask_token() {
  if [[ -n "${GH_TOKEN:-}" ]]; then echo "::add-mask::$GH_TOKEN"; fi
  if [[ -z "${GH_TOKEN:-}" ]]; then
    echo "::error::GH_TOKEN is empty or missing"
    return 1
  fi
}

# token_kind — classify a token by prefix (best-effort, never logged verbatim).
token_kind() {
  case "${GH_TOKEN:-}" in
    ghp_*|gho_*)       echo "classic" ;;
    github_pat_*)      echo "fine-grained" ;;
    ghs_*)             echo "app-installation" ;;
    ghu_*)             echo "user-to-server" ;;
    *)                 echo "unknown" ;;
  esac
}

#---------------------------------------------------------------------------
# curl wrapper — consistent headers, single HTTP code + body file.
#   gh_api METHOD URL [BODY_FILE]  -> echoes HTTP code, writes body (or /dev/null)
#   Use `|| echo 000` at the call site to survive network timeouts.
#---------------------------------------------------------------------------
gh_api() {
  local method="$1" url="$2" body="${3:-/dev/null}"
  curl -sS -o "$body" -w '%{http_code}' \
    -X "$method" \
    -H "Accept: application/vnd.github+json" \
    -H "Authorization: Bearer ${GH_TOKEN}" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    "$url"
}

#---------------------------------------------------------------------------
# GIT_ASKPASS shim — keeps the PAT out of argv and remote URLs.
#   make_askpass OUTPATH  -> writes an askpass script that echoes the token.
# Callers must chmod 0700 and set GIT_ASKPASS/GIT_TERMINAL_PROMPT.
#---------------------------------------------------------------------------
make_askpass() {
  local out="$1"
  cat >"$out" <<'EOS'
#!/usr/bin/env bash
case "$1" in
  Username*) echo "x-access-token" ;;
  Password*) echo "${GH_TOKEN:-}" ;;
esac
EOS
  chmod 0700 "$out"
}

#---------------------------------------------------------------------------
# Git plumbing — SHARED by create (mirror-clone-push), sync (sync-mirror) and
# register. The "same function that created the fork" is the one used to push
# it again: git_push_private with mode=branch (initial) or mode=ff-only (sync).
#---------------------------------------------------------------------------

# git_setup_auth [TAG] — per-run tempdir + askpass shim + git env + EXIT trap.
# Sets $TMPDIR_RUN and $ASKPASS in the caller (sourced function).
git_setup_auth() {
  local tag="${1:-mirror}"
  TMPDIR_RUN="$(mktemp -d -t "${tag}.XXXXXXXX")"
  chmod 0700 "$TMPDIR_RUN"
  trap 'rm -rf "$TMPDIR_RUN"' EXIT
  ASKPASS="$TMPDIR_RUN/askpass.sh"
  make_askpass "$ASKPASS"
  export GIT_ASKPASS="$ASKPASS"
  export GIT_TERMINAL_PROMPT=0
}

# parse_github_url URL -> echoes "OWNER REPO" (validated), non-zero on failure.
# Accepts https/http/ssh forms of a github.com URL.
parse_github_url() {
  local url="${1:-}" path owner repo
  url="${url%.git}"
  url="${url%/}"
  case "$url" in
    https://github.com/*) ;;
    http://github.com/*)  ;;
    git@github.com:*)
      url="https://github.com/${url#git@github.com:}" ;;
    *)
      echo "::error::only github.com URLs supported, got: $1"
      return 1 ;;
  esac
  path="${url#https://github.com/}"
  path="${path#http://github.com/}"
  owner="${path%%/*}"
  repo="${path#*/}"
  repo="${repo%%/*}"
  if [[ -z "$owner" || -z "$repo" || "$owner" == "$repo" ]]; then
    echo "::error::could not parse owner/repo from: $1"
    return 1
  fi
  if ! is_valid_owner_or_repo "$owner" || ! is_valid_owner_or_repo "$repo"; then
    echo "::error::upstream owner/repo contains unsupported characters"
    return 1
  fi
  printf '%s %s\n' "$owner" "$repo"
}

# git_resolve_remote_sha FULL BRANCH -> sha (or empty). ls-remote, token-free read.
git_resolve_remote_sha() {
  local full="$1" branch="$2"
  git ls-remote "https://github.com/${full}.git" "refs/heads/${branch}" 2>/dev/null | awk '{print $1}'
}

# git_clone_upstream UPSTREAM_FULL BRANCH WORKDIR — bare/single-branch (or
# --mirror when BRANCH == "all"). Leaves cwd inside $WORKDIR/mirror.git.
git_clone_upstream() {
  local upstream="$1" branch="$2" workdir="$3"
  mkdir -p "$workdir"
  cd "$workdir"
  echo "Cloning https://github.com/${upstream}.git ..."
  if [[ "$branch" == "all" ]]; then
    git clone --mirror --no-tags "https://github.com/${upstream}.git" mirror.git
  else
    git clone --bare --single-branch --branch "$branch" --no-tags "https://github.com/${upstream}.git" mirror.git
  fi
  cd mirror.git
}

# git_push_private PRIVATE_FULL BRANCH MODE — push to the private mirror.
#   MODE branch   (default) plain push of the branch       (initial mirror)
#   MODE mirror   push --mirror (all refs)                 (initial, branch=all)
#   MODE ff-only  push --force-with-lease (fast-forward)   (sync)
# The PAT goes through GIT_ASKPASS (never in argv/URL). Returns git's exit code.
git_push_private() {
  local private_full="$1" branch="$2" mode="${3:-branch}"
  local push_url="https://github.com/${private_full}.git"
  echo "Pushing to ${private_full} ..."
  case "$mode" in
    mirror)  git push --mirror "$push_url" ;;
    ff-only) git push --force-with-lease "$push_url" "refs/heads/${branch}:refs/heads/${branch}" ;;
    *)       git push "$push_url" "refs/heads/${branch}:refs/heads/${branch}" ;;
  esac
}

# git_ancestry_check UPSTREAM_FULL PRIVATE_FULL UP_SHA PR_SHA WORKDIR
# Determines the relationship of the two SHAs. Echoes one of:
#   equal | private_ahead | upstream_ahead | diverged | unknown
# "unknown" means the shallow clones/fetches failed — conservative treatment.
git_ancestry_check() {
  local upstream="$1" private="$2" up_sha="$3" pr_sha="$4" workdir="$5"
  local up_clone="$workdir/up" pr_clone="$workdir/pr"
  local up_behind_private="no" private_behind_up="no"
  git clone --quiet --filter=blob:none --no-checkout "https://github.com/${upstream}.git" "$up_clone" 2>/dev/null || true
  git clone --quiet --filter=blob:none --no-checkout "https://github.com/${private}.git" "$pr_clone" 2>/dev/null || true
  if [[ -d "$up_clone/.git" && -d "$pr_clone/.git" ]]; then
    git -C "$up_clone" fetch --quiet --depth=1 origin "$up_sha" 2>/dev/null && \
      git -C "$pr_clone" fetch --quiet --depth=1 origin "$pr_sha" 2>/dev/null
    if git -C "$pr_clone" merge-base --is-ancestor "$up_sha" "$pr_sha" 2>/dev/null; then
      up_behind_private="yes"   # private is ahead of upstream
    elif git -C "$up_clone" merge-base --is-ancestor "$pr_sha" "$up_sha" 2>/dev/null; then
      private_behind_up="yes"   # private is behind upstream -> FF push
    fi
  fi
  [[ "$up_behind_private" == "yes" ]] && { echo "private_ahead"; return 0; }
  [[ "$private_behind_up" == "yes" ]] && { echo "upstream_ahead"; return 0; }
  if [[ -d "$up_clone/.git" && -d "$pr_clone/.git" ]]; then echo "diverged"; else echo "unknown"; fi
}

# create_private_repo TARGET_OWNER NAME UPSTREAM_FULL — create a private repo
# under a User (POST /user/repos) or Organization (POST /orgs/{org}/repos).
# Prints the 403 permission diagnostic on failure. Returns non-zero on failure.
create_private_repo() {
  local target_owner="$1" name="$2" upstream_full="$3"
  local owner_json="$TMPDIR_RUN/owner.json" create_json="$TMPDIR_RUN/create.json"
  local ohttp otype create_url desc chttp errmsg
  ohttp="$(gh_api GET "https://api.github.com/users/${target_owner}" "$owner_json" || echo 000)"
  [[ "$ohttp" == "200" ]] || { echo "::error::target owner lookup failed (HTTP $ohttp)"; return 1; }
  otype="$(jq -r '.type' "$owner_json")"
  if [[ "$otype" == "Organization" ]]; then
    create_url="https://api.github.com/orgs/${target_owner}/repos"
  else
    create_url="https://api.github.com/user/repos"
  fi
  desc="$(jq -nc --arg d "Mirror of https://github.com/${upstream_full}" --arg n "$name" \
    '{name:$n, description:$d, private:true, has_issues:true, has_projects:false, has_wiki:false, auto_init:false}')"
  chttp="$(curl -sS -o "$create_json" -w '%{http_code}' -X POST \
    -H "Accept: application/vnd.github+json" \
    -H "Authorization: Bearer ${GH_TOKEN}" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    -d "$desc" "$create_url")"
  if [[ "$chttp" != "201" ]]; then
    errmsg="$(jq -r '.message // .' "$create_json" 2>/dev/null || true)"
    echo "::error::create private repo failed (HTTP $chttp): $errmsg"
    if [[ "$chttp" == "403" ]]; then
      echo "::error::PAT cannot create a repo under '$target_owner'. For a fine-grained PAT grant:"
      echo "  - Resources: 'All repositories' (or this owner), and"
      echo "  - Permissions: 'Administration' read/write + 'Contents' read/write"
      echo "  For a classic PAT, add the 'repo' scope and ensure '$target_owner' allows repo creation."
      echo "  Confirm the PAT in the Actions secret resolved from tracker/owners.json for '$target_owner'."
    fi
    return 1
  fi
  echo "$chttp"
}

# set_default_branch PRIVATE_FULL BRANCH — PATCH the repo's default branch.
# Non-fatal: warns and returns non-zero if the PATCH fails.
set_default_branch() {
  local private_full="$1" branch="$2" http
  http="$(curl -sS -o /dev/null -w '%{http_code}' -X PATCH \
    -H "Accept: application/vnd.github+json" \
    -H "Authorization: Bearer ${GH_TOKEN}" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    -d "$(jq -nc --arg b "$branch" '{default_branch:$b}')" \
    "https://api.github.com/repos/${private_full}")"
  if [[ "$http" != "200" ]]; then
    echo "::warning::failed to set default_branch on $private_full (HTTP $http) — verify manually"
    return 1
  fi
  return 0
}

#---------------------------------------------------------------------------
# Rate-limit helpers
#---------------------------------------------------------------------------

# rate_limit_remaining -> integer (0 if unknown / error)
rate_limit_remaining() {
  local tmp code
  tmp="$(mktemp -d -t rl.XXXXXXXX)"
  code="$(gh_api GET "https://api.github.com/rate_limit" "$tmp/rl.json" || echo 000)"
  if [[ "$code" == "200" ]]; then
    jq -r '.resources.core.remaining // 0' "$tmp/rl.json"
  else
    echo 0
  fi
  rm -rf "$tmp"
}

#---------------------------------------------------------------------------
# Config-driven owner resolution
#   resolve_owner_config OWNER TRACKER_DIR -> prints "SECRET_NAME  ENVIRONMENT" or fails
# Used by the workflows' resolve-secret job AND by local tests.
#---------------------------------------------------------------------------
resolve_owner_config() {
  local owner="$1" tracker_dir="${2:-tracker}" owners_file env_for secret
  is_valid_owner_or_repo "$owner" || { echo "::error::invalid owner '$owner'"; return 1; }
  owners_file="$tracker_dir/owners.json"
  [[ -f "$owners_file" ]] || { echo "::error::owners config missing: $owners_file"; return 1; }
  env_for="$(jq -r --arg o "$owner" '.owners[] | select(.owner == $o) | .environment' "$owners_file" 2>/dev/null || true)"
  secret="$(jq -r --arg o "$owner" '.owners[] | select(.owner == $o) | .secret' "$owners_file" 2>/dev/null || true)"
  if [[ -z "$secret" || "$secret" == "null" || -z "$env_for" || "$env_for" == "null" ]]; then
    echo "owner '$owner' not configured in $owners_file (need secret + environment)"
    return 1
  fi
  printf '%s %s\n' "$secret" "$env_for"
}
