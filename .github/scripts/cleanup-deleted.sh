#!/usr/bin/env bash
# cleanup-deleted.sh
# Scans intent records and checks upstream/private liveness. Instead of deleting
# intent (which is human/PR-owned and would reintroduce write contention), it
# records the observation in the BOT-owned metadata record:
#     upstream_state = active | archived | deleted
# Removing an intent record is a deliberate human action (delete the file via PR).
#
# Env: GH_TOKEN, FULL_REFRESH (unused; accepted for workflow compatibility)

set -euo pipefail

: "${GH_TOKEN:?GH_TOKEN required}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$SCRIPT_DIR/lib-tracker.sh"

mkdir -p "$META_DIR"
mapfile -t reg_files < <(list_registry_files)
(( ${#reg_files[@]} == 0 )) && { echo "no intent records — nothing to check"; exit 0; }

TMPDIR_RUN="$(mktemp -d -t cleanup.XXXXXXXX)"
trap 'rm -rf "$TMPDIR_RUN"' EXIT
chmod 0700 "$TMPDIR_RUN"
U_JSON="$TMPDIR_RUN/up.json"
P_JSON="$TMPDIR_RUN/pr.json"
RL_JSON="$TMPDIR_RUN/rl.json"

rl=$(curl -sS -o "$RL_JSON" -w '%{http_code}' \
  -H "Accept: application/vnd.github+json" \
  -H "Authorization: Bearer ${GH_TOKEN}" \
  -H "X-GitHub-Api-Version: 2022-11-28" \
  "https://api.github.com/rate_limit" || echo 000)
if [[ "$rl" == "200" ]]; then
  remaining=$(jq -r '.resources.core.remaining // 0' "$RL_JSON")
  (( remaining < 50 )) && { echo "::warning::rate limit low ($remaining) — skipping cleanup"; exit 0; }
fi

now_iso="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
marked=0

set_state() {  # key state
  local key="$1" state="$2" up="$3" pr="$4"
  local mf="$META_DIR/$key.json"
  { [[ -f "$mf" ]] && cat "$mf" || jq -nc --arg up "$up" --arg pr "$pr" '{upstream:$up,private:$pr}'; } \
    | jq --arg s "$state" --arg ts "$now_iso" '.upstream_state=$s | .last_validated_at=$ts' \
    | write_json_stable "$mf"
}

for rf in "${reg_files[@]}"; do
  up=$(jq -r '.upstream' "$rf")
  pr=$(jq -r '.private'  "$rf")
  key="$(tracker_key "$pr")"
  is_full_repo "$up" && is_full_repo "$pr" || { echo "::warning::malformed record $(basename "$rf") — skip"; continue; }

  uh=$(curl -sS -o "$U_JSON" -w '%{http_code}' -H "Accept: application/vnd.github+json" \
    -H "Authorization: Bearer ${GH_TOKEN}" -H "X-GitHub-Api-Version: 2022-11-28" \
    "https://api.github.com/repos/${up}" 2>/dev/null || echo 000)
  ph=$(curl -sS -o "$P_JSON" -w '%{http_code}' -H "Accept: application/vnd.github+json" \
    -H "Authorization: Bearer ${GH_TOKEN}" -H "X-GitHub-Api-Version: 2022-11-28" \
    "https://api.github.com/repos/${pr}" 2>/dev/null || echo 000)

  if [[ "$uh" == "403" || "$ph" == "403" ]]; then
    msg=$(jq -r '.message // ""' "$U_JSON" 2>/dev/null || true)
    [[ "$msg" == *"rate limit"* ]] && { echo "::error::rate limit hit — aborting cleanup"; exit 1; }
  fi

  if [[ "$uh" == "404" || "$uh" == "451" ]]; then
    set_state "$key" deleted "$up" "$pr"; marked=$((marked+1))
    echo "::notice::$up upstream deleted (HTTP $uh) — marked deleted"; continue
  fi
  if [[ "$ph" == "404" || "$ph" == "451" ]]; then
    set_state "$key" deleted "$up" "$pr"; marked=$((marked+1))
    echo "::notice::$pr private deleted (HTTP $ph) — marked deleted"; continue
  fi
  if [[ "$uh" == "000" && "$ph" == "000" ]]; then
    echo "::warning::network failure checking $up / $pr — skip"; continue
  fi
  if [[ "$uh" == "200" ]]; then
    arch=$(jq -r '.archived // false' "$U_JSON")
    [[ "$arch" == "true" ]] && { set_state "$key" archived "$up" "$pr"; echo "::notice::$up archived"; }
  fi
done

echo "cleanup: $marked record(s) marked deleted (intent files preserved)"
