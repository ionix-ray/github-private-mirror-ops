#!/usr/bin/env bash
# validate-owner.sh OWNER
# Verifies PAT (env GH_TOKEN) can write to OWNER (user or org).
# Exits non-zero on any failure. Never echoes the token.

set -euo pipefail

OWNER="${1:?owner required}"

if [[ -z "${GH_TOKEN:-}" ]]; then
  echo "::error::GH_TOKEN env not set"
  exit 1
fi

if ! [[ "$OWNER" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,99}$ ]]; then
  echo "::error::owner '$OWNER' has unsupported characters"
  exit 1
fi

TMPDIR_RUN="$(mktemp -d -t valown.XXXXXXXX)"
trap 'rm -rf "$TMPDIR_RUN"' EXIT
OWNER_JSON="$TMPDIR_RUN/owner.json"
ME_JSON="$TMPDIR_RUN/me.json"
MEM_JSON="$TMPDIR_RUN/mem.json"
HDR_FILE="$TMPDIR_RUN/headers.txt"

# Determine if user or org
http=$(curl -sS -o "$OWNER_JSON" -w '%{http_code}' \
  -H "Accept: application/vnd.github+json" \
  -H "Authorization: Bearer ${GH_TOKEN}" \
  -H "X-GitHub-Api-Version: 2022-11-28" \
  "https://api.github.com/users/${OWNER}")

if [[ "$http" != "200" ]]; then
  echo "::error::owner '$OWNER' not found (HTTP $http)"
  exit 1
fi
kind=$(jq -r '.type' "$OWNER_JSON")

# Check the PAT identity actually has rights
who_http=$(curl -sS -o "$ME_JSON" -w '%{http_code}' \
  -H "Accept: application/vnd.github+json" \
  -H "Authorization: Bearer ${GH_TOKEN}" \
  -H "X-GitHub-Api-Version: 2022-11-28" \
  "https://api.github.com/user")
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
  mem_http=$(curl -sS -o "$MEM_JSON" -w '%{http_code}' \
    -H "Accept: application/vnd.github+json" \
    -H "Authorization: Bearer ${GH_TOKEN}" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    "https://api.github.com/orgs/${OWNER}/memberships/${me}")
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
  echo "::error::PAT missing required scopes: ${missing[*]}"
  exit 1
fi

echo "owner=$OWNER kind=$kind validated"
