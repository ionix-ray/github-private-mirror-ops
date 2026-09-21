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

# is_sha SHA -> 0/1 (full or abbreviated hex object id from ls-remote)
is_sha() { [[ "$1" =~ ^[0-9a-f]{4,64}$ ]]; }

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
# curl wrapper — the PAT is read from a 0600 config file, NEVER passed in argv
# (so it cannot leak via `ps`, process inspection, or shell trace).
#   curl_gh [curl args...] URL   -> curl with GitHub auth headers from config
#   gh_api METHOD URL [BODY_FILE]  -> echoes HTTP code, writes body (or /dev/null)
#   Use `|| echo 000` at the call site to survive network timeouts.
#---------------------------------------------------------------------------
curl_gh() {
  local cfg rc=0
  cfg="$(mktemp -t gh.XXXXXXXX)" || return 1
  chmod 0600 "$cfg"
  printf 'header = "Accept: application/vnd.github+json"\nheader = "Authorization: Bearer %s"\nheader = "X-GitHub-Api-Version: 2022-11-28"\n' "${GH_TOKEN:-}" > "$cfg"
  # No RETURN trap: a stale trap would fire on every later function return in
  # the caller (referencing out-of-scope $cfg under `set -u`). Explicit cleanup.
  curl -sS -K "$cfg" "$@" || rc=$?
  rm -f "$cfg"
  return "$rc"
}

gh_api() {
  local method="$1" url="$2" body="${3:-/dev/null}"
  curl_gh -o "$body" -w '%{http_code}' -X "$method" "$url"
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
# Used ONLY by the create path (mirror-clone-push.sh), where the caller cwd IS
# the upstream clone, so pushing the local branch ref pushes upstream content.
#   MODE branch   (default) plain push of the branch       (initial mirror)
#   MODE mirror   push --mirror (all refs)                 (initial, branch=all)
# Sync MUST NOT use this: from the ops-repo checkout the local branch ref is
# the ops repo's own history, not upstream's — pushing it either fails or (with
# --force) would overwrite the mirror with ops content. Sync uses
# git_ff_private below, which pushes the upstream SHA explicitly.
# The PAT goes through GIT_ASKPASS (never in argv/URL). Returns git's exit code.
git_push_private() {
  local private_full="$1" branch="$2" mode="${3:-branch}"
  local push_url="https://github.com/${private_full}.git"
  echo "Pushing to ${private_full} ..."
  case "$mode" in
    mirror)  git push --mirror "$push_url" ;;
    ff-only)
      echo "::error::ff-only mode moved to git_ff_private (needs upstream SHA + workdir); refusing to push a local branch ref"
      return 1
      ;;
    *)       git push "$push_url" "refs/heads/${branch}:refs/heads/${branch}" ;;
  esac
}

# git_ff_private UPSTREAM_FULL PRIVATE_FULL BRANCH UP_SHA WORKDIR — push UP_SHA
# onto the private branch ref as a pure fast-forward (no --force of any kind,
# so a diverged ref is rejected instead of overwritten).
# Pushes from WORKDIR/up (populated by git_ancestry_check); fetches UP_SHA into
# it first if the object is missing. Returns git's exit code.
# GIT_BASE_URL overrides the github.com base (tests point it at local repos).
git_ff_private() {
  local upstream="$1" private="$2" branch="$3" up_sha="$4" workdir="$5"
  local base="${GIT_BASE_URL:-https://github.com}"
  local up_clone="$workdir/up"
  local push_url="${base}/${private}.git"
  is_sha "$up_sha" || { echo "::error::git_ff_private requires a hex UP_SHA, got: '$up_sha'"; return 1; }
  if [[ ! -d "$up_clone/.git" ]]; then
    git clone --quiet --filter=blob:none --no-checkout "${base}/${upstream}.git" "$up_clone" 2>/dev/null || return 1
  fi
  git -C "$up_clone" fetch --quiet origin "$up_sha" 2>/dev/null || return 1
  git -C "$up_clone" push "$push_url" "$up_sha:refs/heads/${branch}"
}

# git_ancestry_check UPSTREAM_FULL PRIVATE_FULL UP_SHA PR_SHA WORKDIR
# Determines the relationship of the two SHAs. Echoes one of:
#   equal | private_ahead | upstream_ahead | diverged | unknown
# "unknown" means the clones/fetches failed — conservative treatment.
# Full-history clones + full (non-shallow) fetches: a --depth=1 fetch would
# truncate history to a single commit and make merge-base --is-ancestor fail
# even for a clean fast-forward, misreporting every behind mirror as diverged.
git_ancestry_check() {
  local upstream="$1" private="$2" up_sha="$3" pr_sha="$4" workdir="$5"
  local base="${GIT_BASE_URL:-https://github.com}"
  local up_clone="$workdir/up" pr_clone="$workdir/pr"
  local up_behind_private="no" private_behind_up="no"
  [[ "$up_sha" == "$pr_sha" ]] && { echo "equal"; return 0; }
  git clone --quiet --filter=blob:none --no-checkout "${base}/${upstream}.git" "$up_clone" 2>/dev/null || true
  git clone --quiet --filter=blob:none --no-checkout "${base}/${private}.git" "$pr_clone" 2>/dev/null || true
  if [[ -d "$up_clone/.git" && -d "$pr_clone/.git" ]]; then
    git -C "$up_clone" fetch --quiet origin "$up_sha" 2>/dev/null || true
    git -C "$up_clone" fetch --quiet origin "$pr_sha" 2>/dev/null || true
    git -C "$pr_clone" fetch --quiet origin "$up_sha" 2>/dev/null || true
    git -C "$pr_clone" fetch --quiet origin "$pr_sha" 2>/dev/null || true
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

#---------------------------------------------------------------------------
# Divergence-noise guards — one open issue / one open pause PR per mirror max.
# The sync cron runs daily; without these every run opens a fresh issue plus a
# fresh timestamped pause/* branch + PR for the same still-diverged mirror
# (50+ pause branches and 100+ duplicate issues observed). Callers check first
# and skip creation when the same mirror already has an open item.
#---------------------------------------------------------------------------

# divergence_issue_exists OPS_REPO TITLE -> 0 when an OPEN issue with exactly
# TITLE exists (paginates up to 10 pages of 100). Returns 1 when absent, 2 on
# lookup error (callers fail CLOSED on 2: never mint a duplicate on an API blip).
divergence_issue_exists() {
  local ops_repo="$1" title="$2"
  local page url http json found
  for page in $(seq 1 10); do
    json="$(mktemp -t divex.XXXXXXXX)" || return 2
    url="https://api.github.com/repos/${ops_repo}/issues?state=open&per_page=100&page=${page}"
    http="$(gh_api GET "$url" "$json" || echo 000)"
    [[ "$http" == "200" ]] || { rm -f "$json"; return 2; }
    found="$(jq -r --arg t "$title" '[.[] | select(.pull_request == null and .title == $t)] | length' "$json" 2>/dev/null || echo 0)"
    if [[ "$found" != "0" ]]; then
      rm -f "$json"
      return 0
    fi
    [[ "$(jq 'length' "$json" 2>/dev/null || echo 0)" -lt 100 ]] && { rm -f "$json"; break; }
    rm -f "$json"
  done
  return 1
}

# pause_pr_exists OPS_REPO PRIVATE_FULL -> 0 when an OPEN pull with title
# "pause: <private> (diverged)" or a head branch matching the auto-pause shape
# "pause/<owner>-<repo>-<14-digit-stamp>" exists. The head match is anchored so
# sibling mirrors sharing a dash-prefix (ionix-ray/cli vs ionix-ray/cli-foo)
# cannot false-positive on each other. Returns 1 when absent, 2 on lookup
# error (callers fail CLOSED on 2: never mint a duplicate branch on a blip).
pause_pr_exists() {
  local ops_repo="$1" private="$2"
  local page url http json found dash_re
  dash_re="${private//\//-}"
  dash_re="${dash_re//./\\.}"
  for page in $(seq 1 10); do
    json="$(mktemp -t prrex.XXXXXXXX)" || return 2
    url="https://api.github.com/repos/${ops_repo}/pulls?state=open&per_page=100&page=${page}"
    http="$(gh_api GET "$url" "$json" || echo 000)"
    [[ "$http" == "200" ]] || { rm -f "$json"; return 2; }
    found="$(jq -r --arg t "pause: $private (diverged)" --arg re "^pause/${dash_re}-[0-9]{14}$" \
      '[.[] | select(.title == $t or ((.head.ref // "") | test($re)))] | length' "$json" 2>/dev/null || echo 0)"
    if [[ "$found" != "0" ]]; then
      rm -f "$json"
      return 0
    fi
    [[ "$(jq 'length' "$json" 2>/dev/null || echo 0)" -lt 100 ]] && { rm -f "$json"; break; }
    rm -f "$json"
  done
  return 1
}

# close_divergence_issues OPS_REPO PRIVATE_FULL REASON — close every OPEN issue
# titled exactly "Mirror diverged: <private>" (bot-created, issues only, never
# PRs) with an explanatory comment. Called when a mirror is verified back in
# sync, so a retriggered run heals the backlog instead of only stemming it.
# Always returns 0 (nothing to close is not an error).
close_divergence_issues() {
  local ops_repo="$1" private="$2" reason="${3:-mirror is back in sync}"
  local title="Mirror diverged: $private"
  local page url http json nums n close_body chttp
  for page in $(seq 1 10); do
    json="$(mktemp -t clsdiv.XXXXXXXX)" || return 1
    url="https://api.github.com/repos/${ops_repo}/issues?state=open&per_page=100&page=${page}"
    http="$(gh_api GET "$url" "$json" || echo 000)"
    # Best-effort healing: an API blip must NEVER fail the sync run under
    # `set -e` (callers invoke this on the ok-path without `|| true`).
    [[ "$http" == "200" ]] || { rm -f "$json"; echo "::warning::issue list unavailable (HTTP $http) — skipping auto-close"; return 0; }
    nums="$(jq -r --arg t "$title" '.[] | select(.pull_request == null and .title == $t) | .number' "$json" 2>/dev/null || true)"
    for n in $nums; do
      [[ "$n" =~ ^[0-9]+$ ]] || continue
      close_body="$(jq -nc --arg r "$reason" '{body:("Auto-closed: " + $r + " — closing stale divergence notice.")}')"
      curl_gh -o /dev/null -w '%{http_code}' -d "$close_body" \
        "https://api.github.com/repos/${ops_repo}/issues/${n}/comments" >/dev/null 2>&1 || true
      chttp="$(curl_gh -o /dev/null -w '%{http_code}' -X PATCH \
        -d '{"state":"closed","state_reason":"completed"}' \
        "https://api.github.com/repos/${ops_repo}/issues/${n}" || echo 000)"
      [[ "$chttp" == "200" ]] && echo "closed stale divergence issue #$n ($private)" \
        || echo "::warning::could not close issue #$n (HTTP $chttp)"
    done
    [[ "$(jq 'length' "$json" 2>/dev/null || echo 0)" -lt 100 ]] && { rm -f "$json"; break; }
    rm -f "$json"
  done
  return 0
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
  chttp="$(curl_gh -o "$create_json" -w '%{http_code}' -X POST \
    -d "$desc" "$create_url" || echo 000)"
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
  http="$(curl_gh -o /dev/null -w '%{http_code}' -X PATCH \
    -d "$(jq -nc --arg b "$branch" '{default_branch:$b}')" \
    "https://api.github.com/repos/${private_full}" || echo 000)"
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
