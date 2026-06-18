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

# Determine if user or org
kind=""
http=$(curl -sS -o /tmp/owner.json -w '%{http_code}' \
  -H "Accept: application/vnd.github+json" \
  -H "Authorization: Bearer ${GH_TOKEN}" \
  -H "X-GitHub-Api-Version: 2022-11-28" \
  "https://api.github.com/users/${OWNER}")

if [[ "$http" != "200" ]]; then
  echo "::error::owner '$OWNER' not found (HTTP $http)"
  exit 1
fi
kind=$(jq -r '.type' /tmp/owner.json)

# Check the PAT identity actually has rights
who_http=$(curl -sS -o /tmp/me.json -w '%{http_code}' \
  -H "Accept: application/vnd.github+json" \
  -H "Authorization: Bearer ${GH_TOKEN}" \
  -H "X-GitHub-Api-Version: 2022-11-28" \
  "https://api.github.com/user")
if [[ "$who_http" != "200" ]]; then
  echo "::error::PAT auth failed (HTTP $who_http)"
  exit 1
fi
me=$(jq -r '.login' /tmp/me.json)

if [[ "$kind" == "User" ]]; then
  if [[ "$me" != "$OWNER" ]]; then
    echo "::error::PAT identity is '$me' but target user is '$OWNER' — classic PATs can only create repos for the user that owns them"
    exit 1
  fi
elif [[ "$kind" == "Organization" ]]; then
  # Org membership check (state must be 'active')
  mem_http=$(curl -sS -o /tmp/mem.json -w '%{http_code}' \
    -H "Accept: application/vnd.github+json" \
    -H "Authorization: Bearer ${GH_TOKEN}" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    "https://api.github.com/orgs/${OWNER}/memberships/${me}")
  if [[ "$mem_http" != "200" ]]; then
    echo "::error::PAT user '$me' is not a member of org '$OWNER' (HTTP $mem_http)"
    exit 1
  fi
  state=$(jq -r '.state' /tmp/mem.json)
  role=$(jq -r '.role'  /tmp/mem.json)
  if [[ "$state" != "active" ]]; then
    echo "::error::membership state is '$state' — PAT must belong to an active org member"
    exit 1
  fi
  echo "owner '$OWNER' is Organization; PAT user '$me' role=$role state=$state"
else
  echo "::error::unsupported owner type '$kind'"
  exit 1
fi

# Confirm required scopes are present on the token
scopes=$(curl -sS -I \
  -H "Authorization: Bearer ${GH_TOKEN}" \
  "https://api.github.com/user" | awk -F': ' 'tolower($1)=="x-oauth-scopes"{print $2}' | tr -d '\r')

echo "PAT scopes: ${scopes:-<none reported>}"
missing=()
for need in repo workflow; do
  case ",$scopes," in
    *",$need,"*) ;;
    *) missing+=("$need") ;;
  esac
done
if (( ${#missing[@]} > 0 )); then
  echo "::error::PAT missing required scopes: ${missing[*]}"
  exit 1
fi

echo "owner=$OWNER kind=$kind validated"
