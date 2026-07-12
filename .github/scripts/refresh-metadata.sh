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

mkdir -p "$META_DIR"

mapfile -t reg_files < <(list_registry_files)
(( ${#reg_files[@]} == 0 )) && { echo "no intent records — skip"; exit 0; }

TMPDIR_RUN="$(mktemp -d -t refresh.XXXXXXXX)"
trap 'rm -rf "$TMPDIR_RUN"' EXIT
chmod 0700 "$TMPDIR_RUN"
U_JSON="$TMPDIR_RUN/up.json"
L_JSON="$TMPDIR_RUN/lang.json"
RL_JSON="$TMPDIR_RUN/rl.json"

# --- Rate limit sanity check ---
rl=$(curl -sS -o "$RL_JSON" -w '%{http_code}' \
  -H "Accept: application/vnd.github+json" \
  -H "Authorization: Bearer ${GH_TOKEN}" \
  -H "X-GitHub-Api-Version: 2022-11-28" \
  "https://api.github.com/rate_limit" || echo 000)
if [[ "$rl" == "200" ]]; then
  remaining=$(jq -r '.resources.core.remaining // 0' "$RL_JSON")
  if (( remaining < 100 )); then
    echo "::warning::rate limit low ($remaining remaining) — skipping metadata refresh"
    exit 0
  fi
fi

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

  # Skip if recently refreshed (unless FULL_REFRESH)
  if [[ "$FULL_REFRESH" != "true" && -f "$mf" ]]; then
    last=$(jq -r '.refreshed_at // ""' "$mf")
    if [[ -n "$last" ]]; then
      last_epoch=$(date -d "$last" +%s 2>/dev/null || echo 0)
      now_epoch=$(date +%s)
      (( now_epoch - last_epoch < 21600 )) && continue
    fi
  fi

  uh=$(curl -sS -o "$U_JSON" -w '%{http_code}' \
    -H "Accept: application/vnd.github+json" \
    -H "Authorization: Bearer ${GH_TOKEN}" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    "https://api.github.com/repos/${up}" 2>/dev/null || echo "000")

  if [[ "$uh" == "403" ]]; then
    msg=$(jq -r '.message // ""' "$U_JSON" 2>/dev/null || true)
    [[ "$msg" == *"rate limit"* ]] && { echo "::error::GitHub rate limit hit — aborting"; exit 1; }
  fi
  if [[ "$uh" == "404" || "$uh" == "451" ]]; then
    echo "::notice::upstream $up not reachable (HTTP $uh) — marking deleted"
    tmp="$TMPDIR_RUN/m.json"
    { [[ -f "$mf" ]] && cat "$mf" || jq -nc --arg up "$up" --arg pr "$pr" '{upstream:$up,private:$pr}'; } \
      | jq --arg ts "$now_iso" '.upstream_state="deleted" | .refreshed_at=$ts' \
      | write_json_stable "$mf"
    continue
  fi
  if [[ "$uh" != "200" ]]; then
    echo "::warning::metadata fetch for $up failed (HTTP $uh)"; continue
  fi

  # Languages
  lh=$(curl -sS -o "$L_JSON" -w '%{http_code}' \
    -H "Accept: application/vnd.github+json" \
    -H "Authorization: Bearer ${GH_TOKEN}" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    "https://api.github.com/repos/${up}/languages" 2>/dev/null || echo "000")
  [[ "$lh" == "200" ]] || echo '{}' > "$L_JSON"

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
