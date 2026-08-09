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
