#!/usr/bin/env bash
# refresh-metadata.sh
# For every INTENT record (tracker/registry/*.json), fetch live upstream data and
# write/refresh the matching BOT-owned metadata record (tracker/metadata/*.json).
#
# Writes ONLY tracker/metadata/* — never tracker/registry/*. That disjointness is
# what keeps the daily refresh from ever conflicting with an open registration PR.
# Existing license_history + sync fields are preserved (merge, not overwrite).
#
# Env: GH_TOKEN, FULL_REFRESH (default false)

set -euo pipefail

: "${GH_TOKEN:?GH_TOKEN required}"
FULL_REFRESH="${FULL_REFRESH:-false}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$SCRIPT_DIR/lib-tracker.sh"
# shellcheck source=/dev/null
. "$SCRIPT_DIR/lib-gh.sh"

mkdir -p "$META_DIR"

mapfile -t reg_files < <(list_registry_files)
(( ${#reg_files[@]} == 0 )) && { echo "no intent records — skip"; exit 0; }

TMPDIR_RUN="$(make_tmpdir refresh)" || exit 1
trap 'rm -rf "$TMPDIR_RUN"' EXIT
U_JSON="$TMPDIR_RUN/up.json"
U_ERR="$TMPDIR_RUN/up.err"
L_JSON="$TMPDIR_RUN/lang.json"

now_iso="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
updated=0

for rf in "${reg_files[@]}"; do
  up=$(jq -r '.upstream' "$rf")
  pr=$(jq -r '.private'  "$rf")
  key="$(tracker_key "$pr")"
  mf="$META_DIR/$key.json"

  if ! is_full_repo "$up"; then
    echo "::warning::malformed upstream '$up' in $(basename "$rf") — skip"; continue
  fi

  # Skip if recently refreshed (default TTL 6h via REFRESH_TTL_S, unless FULL_REFRESH)
  if [[ "$FULL_REFRESH" != "true" && -f "$mf" ]]; then
    last=$(jq -r '.refreshed_at // ""' "$mf")
    if [[ -n "$last" ]]; then
      last_epoch=$(date -d "$last" +%s 2>/dev/null || echo 0)
      now_epoch=$(date +%s)
      (( now_epoch - last_epoch < ${REFRESH_TTL_S:-21600} )) && continue
    fi
  fi

  # Repo snapshot via `gh` (normalized to the REST shape U_JSON expects).
  # Failure classes mirror the old HTTP handling: unresolvable -> deleted,
  # rate exhaustion -> abort, anything else -> warn + skip this repo.
  if ! gh_repo_json "$up" "$U_JSON" "$U_ERR"; then
    if gh_failed_rate_limited "$U_ERR"; then
      echo "::error::GitHub rate limit hit — aborting"; exit 1
    fi
    if gh_failed_not_found "$U_ERR"; then
      echo "::notice::upstream $up not reachable — marking deleted"
      { [[ -f "$mf" ]] && cat "$mf" || jq -nc --arg up "$up" --arg pr "$pr" '{upstream:$up,private:$pr}'; } \
        | jq --arg ts "$now_iso" '.upstream_state="deleted" | .refreshed_at=$ts' \
        | write_json_stable "$mf"
      continue
    fi
    echo "::warning::metadata fetch for $up failed ($(tail -n 1 "$U_ERR" 2>/dev/null || true))"; continue
  fi

  # Languages ride along inside the normalized snapshot (no second call).
  jq '.languages // {}' "$U_JSON" > "$L_JSON"

  # Preserve prior metadata (license_history, sync fields) if present.
  prev="$TMPDIR_RUN/prev.json"
  if [[ -f "$mf" ]]; then cp "$mf" "$prev"; else echo '{}' > "$prev"; fi

  spdx=$(jq -r '.license.spdx_id // "NOASSERTION"' "$U_JSON")
  old_spdx=$(jq -r '.license_current_spdx // ""' "$prev")

  # Assemble new metadata record deterministically. jq merges fetched fields onto
  # the preserved record; license_history is appended only when SPDX changes.
  jq -n \
    --slurpfile up "$U_JSON" \
    --slurpfile langs "$L_JSON" \
    --slurpfile prev "$prev" \
    --arg upfull "$up" \
    --arg prfull "$pr" \
    --arg ts "$now_iso" \
    --arg today "$(date -u +%F)" \
    --arg old_spdx "$old_spdx" '
    ($up[0]) as $u | ($prev[0]) as $p |
    ($u.license.spdx_id // "NOASSERTION") as $spdx |
    ($u.license.name // "") as $lname |
    ($p + {
      upstream: $upfull,
      private:  $prfull,
      upstream_state: (if ($u.archived // false) then "archived" else "active" end),
      description: ($u.description // ""),
      homepage: ($u.homepage // ""),
      language: ($u.language // ""),
      languages: ($langs[0] // {}),
      topics: ($u.topics // []),
      stargazers_count: ($u.stargazers_count // 0),
      forks_count: ($u.forks_count // 0),
      open_issues_count: ($u.open_issues_count // 0),
      watchers_count: ($u.watchers_count // 0),
      network_count: ($u.network_count // 0),
      subscribers_count: ($u.subscribers_count // 0),
      upstream_pushed_at: ($u.pushed_at // ""),
      created_at: ($u.created_at // ""),
      updated_at: ($u.updated_at // ""),
      upstream_default_branch: ($u.default_branch // ""),
      upstream_size_kb: ($u.size // 0),
      upstream_archived: ($u.archived // false),
      is_template: ($u.is_template // false),
      has_discussions: ($u.has_discussions // false),
      has_wiki: ($u.has_wiki // false),
      has_pages: ($u.has_pages // false),
      has_projects: ($u.has_projects // false),
      license_current_spdx: $spdx,
      license_current_name: $lname,
      license_history: (
        ($p.license_history // []) +
        (if ($old_spdx != "" and $old_spdx != $spdx and $old_spdx != "null")
         then [{date:$today, from_spdx:$old_spdx, to_spdx:$spdx, upstream_sha:($u.pushed_at // "")}]
         else [] end)
      ),
      refreshed_at: $ts
    })
  ' | write_json_stable "$mf"

  [[ -n "$old_spdx" && "$old_spdx" != "$spdx" && "$old_spdx" != "null" ]] && \
    echo "::notice::license change: $up $old_spdx -> $spdx"

  updated=$((updated + 1))
  stars=$(jq -r '.stargazers_count // 0' "$mf")
  echo "refreshed $up (stars=$stars)"
done

echo "metadata refreshed for $updated repo(s)"
