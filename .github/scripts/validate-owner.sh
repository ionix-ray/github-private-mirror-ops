#!/usr/bin/env bash
# validate-owner.sh OWNER
# Verifies PAT (env GH_TOKEN) can write to OWNER (user or org).
# Exits non-zero on any failure. Never echoes the token.

set -euo pipefail

OWNER="${1:?owner required}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$SCRIPT_DIR/lib-gh.sh"

is_valid_owner_or_repo "$OWNER" || {
  echo "::error::owner '$OWNER' has unsupported characters"
  exit 1
}

mask_token || exit 1

TMPDIR_RUN="$(mktemp -d -t validate.XXXXXXXX)"
chmod 0700 "$TMPDIR_RUN"
trap 'rm -rf "$TMPDIR_RUN"' EXIT
OWNER_JSON="$TMPDIR_RUN/owner.json"
ME_JSON="$TMPDIR_RUN/me.json"
MEM_JSON="$TMPDIR_RUN/mem.json"
HDR_FILE="$TMPDIR_RUN/headers.txt"

# Determine if user or org
http="$(gh_api GET "https://api.github.com/users/${OWNER}" "$OWNER_JSON")"

if [[ "$http" != "200" ]]; then
  echo "::error::owner '$OWNER' not found (HTTP $http)"
  exit 1
fi
kind=$(jq -r '.type' "$OWNER_JSON")

# Check the PAT identity actually has rights
who_http="$(gh_api GET "https://api.github.com/user" "$ME_JSON")"
if [[ "$who_http" != "200" ]]; then
  echo "::error::PAT auth failed (HTTP $who_http)"
  exit 1
fi
me=$(jq -r '.login' "$ME_JSON")

if [[ "$kind" == "User" ]]; then
  if [[ "$me" != "$OWNER" ]]; then
    echo "::error::PAT identity is '$me' but target user is '$OWNER' — classic PATs can only create repos for the user that owns them"
    exit 1
  fi
elif [[ "$kind" == "Organization" ]]; then
  # Org membership check (state must be 'active')
  mem_http="$(gh_api GET "https://api.github.com/orgs/${OWNER}/memberships/${me}" "$MEM_JSON")"
  if [[ "$mem_http" != "200" ]]; then
    echo "::error::PAT user '$me' is not a member of org '$OWNER' (HTTP $mem_http)"
    exit 1
  fi
  state=$(jq -r '.state' "$MEM_JSON")
  role=$(jq -r '.role'  "$MEM_JSON")
  if [[ "$state" != "active" ]]; then
    echo "::error::membership state is '$state' — PAT must belong to an active org member"
    exit 1
  fi
  echo "owner '$OWNER' is Organization; PAT user '$me' role=$role state=$state"
else
  echo "::error::unsupported owner type '$kind'"
  exit 1
fi

# Detect token style — fine-grained PATs / App tokens don't expose classic scopes.
token_kind_="$(token_kind)"
echo "PAT kind: $token_kind_"

if [[ "$token_kind_" == "classic" ]]; then
  # Confirm required scopes are present on the token.
  # Use -D to dump headers to a file (avoids -I which can be silently dropped by some proxies).
  curl -sS -D "$HDR_FILE" -o /dev/null \
    -H "Authorization: Bearer ${GH_TOKEN}" \
    "https://api.github.com/user"
  scopes=$(awk -F': ' 'tolower($1)=="x-oauth-scopes"{print $2}' "$HDR_FILE" | tr -d '\r')

  echo "PAT scopes: ${scopes:-<none reported>}"
  missing=()
  for need in repo workflow; do
    case ",${scopes// /}," in
      *",$need,"*) ;;
      *) missing+=("$need") ;;
    esac
  done
  if (( ${#missing[@]} > 0 )); then
    echo "::error::classic PAT missing required scopes: ${missing[*]}"
    exit 1
  fi
else
  # Fine-grained PATs / App tokens don't enumerate classic scopes.
  # Probe required permissions functionally instead.
  echo "::notice::token kind '$token_kind_' — skipping classic scope header check; probing permissions instead"

  # Probe 1: token must be able to read its own user record (already done above).
  # Probe 2: token must be able to list private repos (requires repo:read or contents:read).
  probe_http="$(gh_api GET "https://api.github.com/user/repos?per_page=1&visibility=all" /dev/null)"
  if [[ "$probe_http" != "200" ]]; then
    echo "::error::token cannot list user repos (HTTP $probe_http) — needs repo:read / contents:read + administration:write equivalent for create"
    exit 1
  fi
  echo "permission probe passed (user/repos -> HTTP 200)"
  echo "::warning::workflow scope cannot be verified for non-classic tokens at runtime — confirm the fine-grained PAT was issued with 'Actions: read & write' + 'Contents: read & write' + 'Administration: read & write' + 'Workflows: read & write'"
fi

echo "owner=$OWNER kind=$kind validated"
