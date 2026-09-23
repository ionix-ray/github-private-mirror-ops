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
# shellcheck source=/dev/null
. "$SCRIPT_DIR/lib-gh.sh"

mkdir -p "$META_DIR"
mapfile -t reg_files < <(list_registry_files)
(( ${#reg_files[@]} == 0 )) && { echo "no intent records — nothing to check"; exit 0; }

TMPDIR_RUN="$(mktemp -d -t cleanup.XXXXXXXX)"
trap 'rm -rf "$TMPDIR_RUN"' EXIT
chmod 0700 "$TMPDIR_RUN"
U_JSON="$TMPDIR_RUN/up.json"
U_ERR="$TMPDIR_RUN/up.err"
P_JSON="$TMPDIR_RUN/pr.json"
P_ERR="$TMPDIR_RUN/pr.err"

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

  up_ok=0; pr_ok=0
  if gh_repo_json "$up" "$U_JSON" "$U_ERR"; then up_ok=1; fi
  if gh_repo_json "$pr" "$P_JSON" "$P_ERR"; then pr_ok=1; fi

  if (( up_ok == 0 )) && gh_failed_rate_limited "$U_ERR"; then
    echo "::error::rate limit hit — aborting cleanup"; exit 1
  fi

  if (( up_ok == 0 )) && gh_failed_not_found "$U_ERR"; then
    set_state "$key" deleted "$up" "$pr"; marked=$((marked+1))
    echo "::notice::$up upstream deleted — marked deleted"; continue
  fi
  if (( pr_ok == 0 )) && gh_failed_not_found "$P_ERR"; then
    set_state "$key" deleted "$up" "$pr"; marked=$((marked+1))
    echo "::notice::$pr private deleted — marked deleted"; continue
  fi
  if (( up_ok == 0 && pr_ok == 0 )); then
    echo "::warning::lookup failed for $up / $pr ($(tail -n 1 "$U_ERR" 2>/dev/null || true)) — skip"; continue
  fi
  if (( up_ok == 1 )); then
    arch=$(jq -r '.archived // false' "$U_JSON")
    [[ "$arch" == "true" ]] && { set_state "$key" archived "$up" "$pr"; echo "::notice::$up archived"; }
  fi
done

echo "cleanup: $marked record(s) marked deleted (intent files preserved)"
