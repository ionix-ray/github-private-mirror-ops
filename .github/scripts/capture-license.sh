#!/usr/bin/env bash
# capture-license.sh UPSTREAM_FULL
# Bot-side helper: refreshes license fields in the metadata record for the mirror
# whose intent record has upstream == UPSTREAM_FULL. Appends to license_history on
# change. Writes ONLY tracker/metadata/<key>.json (bot-owned) — never intent files.
# No-op if the upstream is not registered yet.
#
# Env: GH_TOKEN

set -euo pipefail

UPSTREAM="${1:?upstream owner/repo required}"
: "${GH_TOKEN:?}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$SCRIPT_DIR/lib-tracker.sh"

is_full_repo "$UPSTREAM" || { echo "::error::capture-license: bad upstream: $UPSTREAM"; exit 1; }

# Find the intent record with this upstream to learn the private key.
priv=""
while IFS= read -r f; do
  [[ -z "$f" ]] && continue
  if [[ "$(jq -r '.upstream' "$f")" == "$UPSTREAM" ]]; then
    priv="$(jq -r '.private' "$f")"; break
  fi
done < <(list_registry_files)

if [[ -z "$priv" ]]; then
  echo "$UPSTREAM not registered yet — license will be captured on next sync"
  exit 0
fi

key="$(tracker_key "$priv")"
mf="$META_DIR/$key.json"
mkdir -p "$META_DIR"

TMPDIR_RUN="$(mktemp -d -t caplic.XXXXXXXX)"
trap 'rm -rf "$TMPDIR_RUN"' EXIT
chmod 0700 "$TMPDIR_RUN"
LIC_JSON="$TMPDIR_RUN/lic.json"

http=$(curl -sS -o "$LIC_JSON" -w '%{http_code}' \
  -H "Accept: application/vnd.github+json" \
  -H "Authorization: Bearer ${GH_TOKEN}" \
  -H "X-GitHub-Api-Version: 2022-11-28" \
  "https://api.github.com/repos/${UPSTREAM}" || echo 000)
[[ "$http" == "200" ]] || { echo "::warning::license capture: upstream lookup failed (HTTP $http)"; exit 0; }

spdx=$(jq -r '.license.spdx_id // "NOASSERTION"' "$LIC_JSON")
name=$(jq -r '.license.name // ""'               "$LIC_JSON")

prev="$TMPDIR_RUN/prev.json"
{ [[ -f "$mf" ]] && cat "$mf" || jq -nc --arg up "$UPSTREAM" --arg pr "$priv" '{upstream:$up,private:$pr}'; } > "$prev"
old_spdx=$(jq -r '.license_current_spdx // ""' "$prev")

jq --arg spdx "$spdx" --arg name "$name" --arg old "$old_spdx" --arg today "$(date -u +%F)" '
  .license_current_spdx = $spdx
  | .license_current_name = $name
  | .license_history = ((.license_history // []) +
      (if ($old != "" and $old != $spdx and $old != "null")
       then [{date:$today, from_spdx:$old, to_spdx:$spdx, upstream_sha:""}] else [] end))
' "$prev" | write_json_stable "$mf"

[[ -n "$old_spdx" && "$old_spdx" != "$spdx" && "$old_spdx" != "null" ]] && \
  echo "::notice::license change detected for $UPSTREAM: $old_spdx -> $spdx"
echo "license captured: $UPSTREAM spdx=$spdx"
