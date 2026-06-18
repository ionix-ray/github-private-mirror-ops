#!/usr/bin/env bash
# capture-license.sh UPSTREAM_FULL
# Updates synced-repos.yml entry with current license SPDX from upstream.
# Appends to license_history if changed since last capture.
# No-op if entry not in registry yet (Workflow A may call before register-repo).

set -euo pipefail

UPSTREAM="${1:?upstream owner/repo required}"
REG=".github/synced-repos.yml"
: "${GH_TOKEN:?}"

if [[ ! -f "$REG" ]]; then
  echo "registry $REG missing — skip"
  exit 0
fi

http=$(curl -sS -o /tmp/lic.json -w '%{http_code}' \
  -H "Accept: application/vnd.github+json" \
  -H "Authorization: Bearer ${GH_TOKEN}" \
  -H "X-GitHub-Api-Version: 2022-11-28" \
  "https://api.github.com/repos/${UPSTREAM}")
if [[ "$http" != "200" ]]; then
  echo "::warning::license capture: upstream lookup failed (HTTP $http)"
  exit 0
fi

spdx=$(jq -r '.license.spdx_id // "NOASSERTION"' /tmp/lic.json)
name=$(jq -r '.license.name // ""'               /tmp/lic.json)

idx=$(yq -r ".repos | to_entries | map(select(.value.upstream == \"$UPSTREAM\")) | .[0].key // \"\"" "$REG")
if [[ -z "$idx" || "$idx" == "null" ]]; then
  echo "$UPSTREAM not registered yet — license will be captured on registration"
  exit 0
fi

old_spdx=$(yq -r ".repos[$idx].license_current_spdx // \"\"" "$REG")

if [[ -n "$old_spdx" && "$old_spdx" != "$spdx" ]]; then
  # license change — append history
  today=$(date -u +%F)
  yq -i ".repos[$idx].license_history = ((.repos[$idx].license_history // []) + [{\"date\": \"$today\", \"from_spdx\": \"$old_spdx\", \"to_spdx\": \"$spdx\", \"upstream_sha\": \"\"}])" "$REG"
  echo "::notice::license change detected for $UPSTREAM: $old_spdx -> $spdx"
fi

yq -i ".repos[$idx].license_current_spdx = \"$spdx\"" "$REG"
yq -i ".repos[$idx].license_current_name = \"$name\"" "$REG"

echo "license captured: $UPSTREAM spdx=$spdx"
