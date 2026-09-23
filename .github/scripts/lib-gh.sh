#!/usr/bin/env bash
# lib-gh.sh — shared GitHub + hardening helpers for mirror-ops scripts.
# Source from scripts:  . "$(dirname "$0")/lib-gh.sh"
#
# Auth model: the `gh` CLI and `git` read GH_TOKEN from the environment
# (Actions secret store via the workflow env). Scripts NEVER handle, print, or
# pass the token: no curl, no Authorization headers, no token in argv/URLs.
# Presence is asserted (require_gh_token); the value is never echoed.
#
# All functions are pure (no global state) except those that export the
# per-run tempdir, so they are unit-testable offline. Dependencies: bash +
# git + gh + jq, all preinstalled on ubuntu-latest runners.

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

# require_gh_token — assert the CLI + secret-store token exist. Never prints it.
require_gh_token() {
  command -v gh >/dev/null 2>&1 || { echo "::error::gh CLI not found on PATH"; return 1; }
  [[ -n "${GH_TOKEN:-}" ]] || { echo "::error::GH_TOKEN is empty or missing (must come from the Actions secret store)"; return 1; }
}

#---------------------------------------------------------------------------
# GitHub access — everything goes through `gh` (auth from GH_TOKEN env) or
# plain `git`. No raw REST, no curl, no token plumbing in scripts.
# Convention: helpers returning data take OUTFILE (+ optional ERRFILE) args
# and return 0/1; callers classify failures via gh_failed_* on the stderr file.
#---------------------------------------------------------------------------

# gh_repo_fields — GraphQL fields fetched for one repo snapshot.
GH_REPO_FIELDS="nameWithOwner,description,homepageUrl,primaryLanguage,languages,repositoryTopics,stargazerCount,forkCount,issues,watchers,createdAt,updatedAt,pushedAt,defaultBranchRef,diskUsage,isArchived,isTemplate,hasDiscussionsEnabled,hasWikiEnabled,hasProjectsEnabled,licenseInfo,isPrivate,visibility"

# gh_repo_json FULL OUTFILE [ERRFILE] -> 0 with normalized REST-shaped JSON.
# Normalizes the gh (GraphQL) shape to the REST shape downstream jq already
# expects, so callers keep their field names. Keys without a gh equivalent
# (has_pages) default; network/subscriber counts map to their closest counter.
gh_repo_json() {
  local full="$1" out="$2" err="${3:-/dev/null}"
  local raw; raw="$(mktemp -t ghrepo.XXXXXXXX)" || return 1
  if ! gh repo view "$full" --json "$GH_REPO_FIELDS" >"$raw" 2>"$err"; then
    rm -f "$raw"; return 1
  fi
  gh_normalize_repo "$raw" >"$out"
  rm -f "$raw"
}

# gh_normalize_repo RAW_FILE -> REST-shaped JSON on stdout. Pure jq, offline,
# unit-tested. License keys map to canonical SPDX IDs so license_history does
# not flap on GraphQL-vs-REST casing (apache-2.0 vs Apache-2.0).
gh_normalize_repo() {
  jq '{description: (.description // ""),
       homepage: (.homepageUrl // ""),
       language: (.primaryLanguage.name // ""),
       languages: ([.languages[]? | {key: .node.name, value: .size}] | from_entries),
       topics: ([.repositoryTopics[]?.name] // []),
       stargazers_count: (.stargazerCount // 0),
       forks_count: (.forkCount // 0),
       open_issues_count: (.issues.totalCount // 0),
       watchers_count: (.watchers.totalCount // 0),
       network_count: (.forkCount // 0),
       subscribers_count: (.watchers.totalCount // 0),
       pushed_at: (.pushedAt // ""),
       created_at: (.createdAt // ""),
       updated_at: (.updatedAt // ""),
       default_branch: (.defaultBranchRef.name // ""),
       size: (.diskUsage // 0),
       archived: (.isArchived // false),
       is_template: (.isTemplate // false),
       has_discussions: (.hasDiscussionsEnabled // false),
       has_wiki: (.hasWikiEnabled // false),
       has_pages: false,
       has_projects: (.hasProjectsEnabled // false),
       license: {spdx_id: (
         (.licenseInfo.key // null) as $k |
         if $k == null then null
         else ({"mit":"MIT","apache-2.0":"Apache-2.0",
                "gpl-2.0":"GPL-2.0","gpl-3.0":"GPL-3.0",
                "agpl-3.0":"AGPL-3.0","lgpl-2.1":"LGPL-2.1","lgpl-3.0":"LGPL-3.0",
                "mpl-2.0":"MPL-2.0","bsd-2-clause":"BSD-2-Clause",
                "bsd-3-clause":"BSD-3-Clause","bsd-3-clause-clear":"BSD-3-Clause-Clear",
                "isc":"ISC","unlicense":"Unlicense","cc0-1.0":"CC0-1.0",
                "epl-1.0":"EPL-1.0","epl-2.0":"EPL-2.0",
                "eupl-1.1":"EUPL-1.1","eupl-1.2":"EUPL-1.2",
                "artistic-2.0":"Artistic-2.0"}[$k] // ($k | ascii_upcase))
         end),
         name: (.licenseInfo.name // "")},
       visibility: ((.visibility // "") | ascii_downcase),
       private: (.isPrivate // false)}' "$1"
}

# gh_failed_rate_limited ERRFILE -> 0 when stderr reports exhaustion.
gh_failed_rate_limited() { grep -qi "rate limit" "$1" 2>/dev/null; }

# gh_failed_not_found ERRFILE -> 0 when stderr reports a missing repo.
gh_failed_not_found() { grep -qi "could not resolve to a repository\|not found\|404" "$1" 2>/dev/null; }

# gh_repo_list_public OWNER LIMIT OUTFILE [ERRFILE] — public repos as
# [{full_name, private}] (REST-shaped names for the existing discovery loop).
gh_repo_list_public() {
  local owner="$1" limit="$2" out="$3" err="${4:-/dev/null}"
  local raw; raw="$(mktemp -t ghlist.XXXXXXXX)" || return 1
  if ! gh repo list "$owner" --visibility public --limit "$limit" \
      --json nameWithOwner,isPrivate >"$raw" 2>"$err"; then
    rm -f "$raw"; return 1
  fi
  jq '[.[] | {full_name: .nameWithOwner, private: .isPrivate}]' "$raw" >"$out"
  rm -f "$raw"
}

# gh_create_private TARGET NAME DESC — create a private mirror (issues on,
# wiki off, matching the old REST flags; projects follow the gh default).
# Auth + permission failures surface via gh stderr at the call site.
gh_create_private() {
  gh repo create "${1}/${2}" --private --description "$3" --disable-wiki
}

# gh_delete_repo FULL — hard delete (bulk-import rollback / confirmed cleanup).
gh_delete_repo() { gh repo delete "$1" --yes; }

# gh_set_default_branch FULL BRANCH — non-fatal at call site (warn + continue).
gh_set_default_branch() { gh repo edit "$1" --default-branch "$2"; }

# gh_open_pr OPS_REPO TITLE HEAD BODY — echoes the PR URL on success.
gh_open_pr() {
  gh pr create --repo "$1" --title "$2" --head "$3" --base main --body "$4"
}

# gh_open_issue OPS_REPO TITLE BODY — echoes the issue URL on success.
gh_open_issue() {
  gh issue create --repo "$1" --title "$2" --body "$3"
}

# gh_list_open_issues OPS_REPO OUTFILE [ERRFILE] — [{number,title}] (no PRs:
# `gh issue list` never returns pull requests).
gh_list_open_issues() {
  gh issue list --repo "$1" --state open --limit 1000 --json number,title >"$2" 2>"${3:-/dev/null}"
}

# gh_list_open_prs OPS_REPO OUTFILE [ERRFILE] — [{number,title,headRefName}].
gh_list_open_prs() {
  gh pr list --repo "$1" --state open --limit 1000 --json number,title,headRefName >"$2" 2>"${3:-/dev/null}"
}

# gh_close_issue OPS_REPO NUMBER MSG — comment + completed-close.
gh_close_issue() {
  gh issue comment "$2" --repo "$1" --body "$3" && \
  gh issue close "$2" --repo "$1" --reason completed
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
# TITLE exists (`gh issue list` never returns pull requests). Returns 1 when
# absent, 2 on lookup error (callers fail CLOSED on 2: never mint a duplicate).
divergence_issue_exists() {
  local ops_repo="$1" title="$2"
  local json; json="$(mktemp -t divex.XXXXXXXX)" || return 2
  local err; err="$(mktemp -t divex.XXXXXXXX)" || { rm -f "$json"; return 2; }
  if ! gh_list_open_issues "$ops_repo" "$json" "$err"; then
    rm -f "$json" "$err"; return 2
  fi
  rm -f "$err"
  local found
  found="$(jq -r --arg t "$title" '[.[] | select(.title == $t)] | length' "$json" 2>/dev/null || echo 0)"
  rm -f "$json"
  [[ "$found" != "0" ]]
}

# pause_pr_exists OPS_REPO PRIVATE_FULL -> 0 when an OPEN pull with title
# "pause: <private> (diverged)" or a head branch matching the auto-pause shape
# "pause/<owner>-<repo>-<14-digit-stamp>" exists. The head match is anchored so
# sibling mirrors sharing a dash-prefix (ionix-ray/cli vs ionix-ray/cli-foo)
# cannot false-positive on each other. Returns 1 when absent, 2 on lookup
# error (callers fail CLOSED on 2: never mint a duplicate branch on a blip).
pause_pr_exists() {
  local ops_repo="$1" private="$2"
  local json; json="$(mktemp -t prrex.XXXXXXXX)" || return 2
  local err; err="$(mktemp -t prrex.XXXXXXXX)" || { rm -f "$json"; return 2; }
  if ! gh_list_open_prs "$ops_repo" "$json" "$err"; then
    rm -f "$json" "$err"; return 2
  fi
  rm -f "$err"
  local dash_re="${private//\//-}"
  dash_re="${dash_re//./\\.}"
  local found
  found="$(jq -r --arg t "pause: $private (diverged)" --arg re "^pause/${dash_re}-[0-9]{14}$" \
    '[.[] | select(.title == $t or ((.headRefName // "") | test($re)))] | length' "$json" 2>/dev/null || echo 0)"
  rm -f "$json"
  [[ "$found" != "0" ]]
}

# close_divergence_issues OPS_REPO PRIVATE_FULL REASON — close every OPEN issue
# titled exactly "Mirror diverged: <private>" (bot-created, issues only, never
# PRs) with an explanatory comment. Called when a mirror is verified back in
# sync, so a retriggered run heals the backlog instead of only stemming it.
# Always returns 0 (nothing to close is not an error).
close_divergence_issues() {
  local ops_repo="$1" private="$2" reason="${3:-mirror is back in sync}"
  local title="Mirror diverged: $private"
  local json err nums n
  json="$(mktemp -t clsdiv.XXXXXXXX)" || return 1
  err="$(mktemp -t clsdiv.XXXXXXXX)" || { rm -f "$json"; return 1; }
  # Best-effort healing: a list failure must NEVER fail the sync run under
  # `set -e` (callers invoke this on the ok-path without `|| true`).
  if ! gh_list_open_issues "$ops_repo" "$json" "$err"; then
    rm -f "$json" "$err"
    echo "::warning::issue list unavailable — skipping auto-close"
    return 0
  fi
  rm -f "$err"
  nums="$(jq -r --arg t "$title" '.[] | select(.title == $t) | .number' "$json" 2>/dev/null || true)"
  rm -f "$json"
  for n in $nums; do
    [[ "$n" =~ ^[0-9]+$ ]] || continue
    if gh_close_issue "$ops_repo" "$n" "Auto-closed: $reason — closing stale divergence notice." >/dev/null 2>&1; then
      echo "closed stale divergence issue #$n ($private)"
    else
      echo "::warning::could not close issue #$n"
    fi
  done
  return 0
}

# create_private_repo TARGET_OWNER NAME UPSTREAM_FULL — create a private mirror
# (issues on, wiki off) via `gh`. Prints the permission diagnostic on failure.
# Returns non-zero on failure. Auth comes from GH_TOKEN env (secret store).
create_private_repo() {
  local target_owner="$1" name="$2" upstream_full="$3"
  local desc="Mirror of https://github.com/${upstream_full}"
  local err; err="$(mktemp -t create.XXXXXXXX)" || return 1
  if gh_create_private "$target_owner" "$name" "$desc" 2>"$err"; then
    rm -f "$err"; return 0
  fi
  local errmsg; errmsg="$(tail -n 3 "$err" 2>/dev/null || true)"
  rm -f "$err"
  echo "::error::create private repo failed: $errmsg"
  echo "::error::PAT cannot create a repo under '$target_owner'. For a fine-grained PAT grant:"
  echo "  - Resources: 'All repositories' (or this owner), and"
  echo "  - Permissions: 'Administration' read/write + 'Contents' read/write"
  echo "  For a classic PAT, add the 'repo' scope and ensure '$target_owner' allows repo creation."
  echo "  Confirm the PAT in the Actions secret resolved from tracker/owners.json for '$target_owner'."
  return 1
}

# set_default_branch PRIVATE_FULL BRANCH — set the default branch via `gh`.
# Non-fatal: warns and returns non-zero if it fails.
set_default_branch() {
  local private_full="$1" branch="$2" err
  err="$(mktemp -t defbr.XXXXXXXX)" || return 1
  if gh_set_default_branch "$private_full" "$branch" 2>"$err"; then
    rm -f "$err"; return 0
  fi
  echo "::warning::failed to set default_branch on $private_full — verify manually ($(tail -n 1 "$err" 2>/dev/null || true))"
  rm -f "$err"
  return 1
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
