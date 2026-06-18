#!/usr/bin/env bash
# capture-license.sh UPSTREAM_FULL
# Updates synced-repos.yml entry with current license SPDX from upstream.
# Appends to license_history if changed since last capture.
# No-op if entry not in registry yet (Workflow A may call before register-repo).

set -euo pipefail

UPSTREAM="${1:?upstream owner/repo required}"
REG=".github/synced-repos.yml"
: "${GH_TOKEN:?}"

# Charset hardening — upstream must be owner/repo with safe chars only.
if ! [[ "$UPSTREAM" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*/[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
  echo "::error::capture-license: UPSTREAM has unsupported characters: $UPSTREAM"
  exit 1
fi

if [[ ! -f "$REG" ]]; then
  echo "registry $REG missing — skip"
  exit 0
fi

TMPDIR_RUN="$(0)"
chmod 0700 "$TMPDIR_RUN"
trap 'rm -rf "$TMPDIR_RUN"' EXIT
LIC_JSON="$TMPDIR_RUN/lic.json"

http=$(curl -sS -o "$LIC_JSON" -w '%{http_code}' \
  -H "Accept: application/vnd.github+json" \
  -H "Authorization: Bearer ${GH_TOKEN}" \
  -H "X-GitHub-Api-Version: 2022-11-28" \
  "https://api.github.com/repos/${UPSTREAM}")
if [[ "$http" != "200" ]]; then
  echo "::warning::license capture: upstream lookup failed (HTTP $http)"
  exit 0
fi

spdx=$(jq -r '.license.spdx_id // "NOASSERTION"' "$LIC_JSON")
name=$(jq -r '.license.name // ""'               "$LIC_JSON")

# Lookup index via env() — attacker-controlled UPSTREAM cannot escape yq filter.
idx=$(UP="$UPSTREAM" yq -r '.repos | to_entries | map(select(.value.upstream == strenv(UP))) | .[0].key // ""' "$REG")
if [[ -z "$idx" || "$idx" == "null" ]]; then
  echo "$UPSTREAM not registered yet — license will be captured on registration"
  exit 0
fi
# Idx must be a non-negative integer (yq returns the entry key).
if ! [[ "$idx" =~ ^[0-9]+$ ]]; then
  echo "::error::capture-license: unexpected idx value '$idx'"
  exit 1
fi

old_spdx=$(IDX="$idx" yq -r '.repos[env(IDX) | tonumber].license_current_spdx // ""' "$REG")

if [[ -n "$old_spdx" && "$old_spdx" != "$spdx" ]]; then
  today=$(date -u +%F)
  IDX="$idx" SPDX="$spdx" OLD="$old_spdx" DATE="$today" \
    yq -i '
      .repos[env(IDX) | tonumber].license_history =
        ((.repos[env(IDX) | tonumber].license_history // []) +
         [{"date": strenv(DATE), "from_spdx": strenv(OLD), "to_spdx": strenv(SPDX), "upstream_sha": ""}])
    ' "$REG"
  echo "::notice::license change detected for $UPSTREAM: $old_spdx -> $spdx"
fi

IDX="$idx" SPDX="$spdx" yq -i '.repos[env(IDX) | tonumber].license_current_spdx = strenv(SPDX)' "$REG"
IDX="$idx" NAME="$name" yq -i '.repos[env(IDX) | tonumber].license_current_name = strenv(NAME)' "$REG"

echo "license captured: $UPSTREAM spdx=$spdx"
