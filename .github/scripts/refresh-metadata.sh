#!/usr/bin/env bash
# refresh-metadata.sh
# Enriches every entry in synced-repos.yml with live metadata from GitHub API.
# Updates: description, stars, forks, issues, language, topics, pushed_at,
#          default_branch, size, license, archived status, and more.
# Respects rate limits; exits non-zero on rate-limit exhaustion.
#
# Env: GH_TOKEN, REG (default .github/synced-repos.yml), FULL_REFRESH (default false)

set -euo pipefail

: "${GH_TOKEN:?}" || { echo "::error::GH_TOKEN required"; exit 1; }
REG="${REG:-.github/synced-repos.yml}"
FULL_REFRESH="${FULL_REFRESH:-false}"

if [[ ! -f "$REG" ]]; then
  echo "registry missing — skip"
  exit 0
fi

TMPDIR_RUN="$(mktemp -d -t refresh.XXXXXXXX)"
trap 'rm -rf "$TMPDIR_RUN"' EXIT
chmod 0700 "$TMPDIR_RUN"

U_JSON="$TMPDIR_RUN/up.json"
L_JSON="$TMPDIR_RUN/lang.json"
RATE_LIMIT_CHECK="$TMPDIR_RUN/ratelimit.json"

# --- Rate limit sanity check first ---
rl=$(curl -sS -o "$RATE_LIMIT_CHECK" -w '%{http_code}' \
  -H "Accept: application/vnd.github+json" \
  -H "Authorization: Bearer ${GH_TOKEN}" \
  -H "X-GitHub-Api-Version: 2022-11-28" \
  "https://api.github.com/rate_limit")
if [[ "$rl" == "200" ]]; then
  remaining=$(jq -r '.resources.core.remaining // 0' "$RATE_LIMIT_CHECK")
  if (( remaining < 100 )); then
    echo "::warning::rate limit low ($remaining remaining) — skipping metadata refresh"
    exit 0
  fi
fi

count=$(yq -r '.repos | length' "$REG")
[[ "$count" =~ ^[0-9]+$ ]] || { echo "::error::invalid repo count"; exit 1; }
(( count == 0 )) && { echo "registry empty — skip"; exit 0; }

updated=0
for i in $(seq 0 $((count - 1))); do
  up=$(IDX="$i" yq -r '.repos[env(IDX) | tonumber].upstream' "$REG")

  if ! [[ "$up" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*/[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
    echo "::warning::malformed upstream '$up' at index $i — skip"
    continue
  fi

  # Skip if recently updated and not full_refresh
  if [[ "$FULL_REFRESH" != "true" ]]; then
    last_up=$(IDX="$i" yq -r '.repos[env(IDX) | tonumber].updated_at // ""' "$REG")
    if [[ -n "$last_up" ]]; then
      last_epoch=$(date -d "$last_up" +%s 2>/dev/null || echo 0)
      now_epoch=$(date +%s)
      if (( now_epoch - last_epoch < 21600 )); then
        continue
      fi
    fi
  fi

  uh=$(curl -sS -o "$U_JSON" -w '%{http_code}' \
    -H "Accept: application/vnd.github+json" \
    -H "Authorization: Bearer ${GH_TOKEN}" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    "https://api.github.com/repos/${up}" 2>/dev/null || echo "000")

  if [[ "$uh" == "403" ]]; then
    msg=$(jq -r '.message // ""' "$U_JSON" 2>/dev/null || true)
    if [[ "$msg" == *"rate limit"* ]]; then
      echo "::error::GitHub rate limit hit — aborting metadata refresh"
      exit 1
    fi
  fi

  if [[ "$uh" != "200" ]]; then
    echo "::warning::metadata fetch for $up failed (HTTP $uh)"
    continue
  fi

  # Core fields
  desc=$(jq -r '.description // ""' "$U_JSON" | sed 's/"/\\"/g')
  homepage=$(jq -r '.homepage // ""' "$U_JSON" | sed 's/"/\\"/g')
  language=$(jq -r '.language // ""' "$U_JSON")
  stars=$(jq -r '.stargazers_count // 0' "$U_JSON")
  forks=$(jq -r '.forks_count // 0' "$U_JSON")
  issues=$(jq -r '.open_issues_count // 0' "$U_JSON")
  watchers=$(jq -r '.watchers_count // 0' "$U_JSON")
  network=$(jq -r '.network_count // 0' "$U_JSON")
  subs=$(jq -r '.subscribers_count // 0' "$U_JSON")
  pushed=$(jq -r '.pushed_at // ""' "$U_JSON")
  created=$(jq -r '.created_at // ""' "$U_JSON")
  updated=$(jq -r '.updated_at // ""' "$U_JSON")
  default_branch=$(jq -r '.default_branch // ""' "$U_JSON")
  size_kb=$(jq -r '.size // 0' "$U_JSON")
  archived=$(jq -r '.archived // false' "$U_JSON")
  template=$(jq -r '.is_template // false' "$U_JSON")
  has_disc=$(jq -r '.has_discussions // false' "$U_JSON")
  has_wiki=$(jq -r '.has_wiki // false' "$U_JSON")
  has_pages=$(jq -r '.has_pages // false' "$U_JSON")
  has_proj=$(jq -r '.has_projects // false' "$U_JSON")
  spdx=$(jq -r '.license.spdx_id // "NOASSERTION"' "$U_JSON")
  lic_name=$(jq -r '.license.name // ""' "$U_JSON")

  # Topics array as JSON string
  topics_json=$(jq -c '[.topics // [] | .[]]' "$U_JSON" 2>/dev/null || echo "[]")

  # Languages
  lh=$(curl -sS -o "$L_JSON" -w '%{http_code}' \
    -H "Accept: application/vnd.github+json" \
    -H "Authorization: Bearer ${GH_TOKEN}" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    "https://api.github.com/repos/${up}/languages" 2>/dev/null || echo "000")
  if [[ "$lh" == "200" ]]; then
    langs_json=$(cat "$L_JSON")
  else
    langs_json='{}'
  fi

  update_str() {
    local field="$1" val="$2"
    IDX="$i" VAL="$val" yq -i ".repos[env(IDX) | tonumber].$field = strenv(VAL)" "$REG" 2>/dev/null || true
  }
  update_int() {
    local field="$1" val="$2"
    IDX="$i" VAL="$val" yq -i ".repos[env(IDX) | tonumber].$field = (env(VAL) | tonumber)" "$REG" 2>/dev/null || true
  }
  update_bool() {
    local field="$1" val="$2"
    IDX="$i" VAL="$val" yq -i ".repos[env(IDX) | tonumber].$field = (env(VAL) == \"true\")" "$REG" 2>/dev/null || true
  }

  update_str  "description"               "$desc"
  update_str  "homepage"                  "$homepage"
  update_str  "language"                  "$language"
  update_int  "stargazers_count"          "$stars"
  update_int  "forks_count"               "$forks"
  update_int  "open_issues_count"         "$issues"
  update_int  "watchers_count"            "$watchers"
  update_int  "network_count"             "$network"
  update_int  "subscribers_count"         "$subs"
  update_str  "upstream_pushed_at"        "$pushed"
  update_str  "created_at"                "$created"
  update_str  "updated_at"                "$updated"
  update_str  "upstream_default_branch"   "$default_branch"
  update_int  "upstream_size_kb"          "$size_kb"
  update_bool "upstream_archived"         "$archived"
  update_bool "is_template"               "$template"
  update_bool "has_discussions"           "$has_disc"
  update_bool "has_wiki"                  "$has_wiki"
  update_bool "has_pages"                 "$has_pages"
  update_bool "has_projects"              "$has_proj"
  update_str  "license_current_spdx"      "$spdx"
  update_str  "license_current_name"      "$lic_name"

  # Topics
  IDX="$i" TOPICS="$topics_json" yq -i ".repos[env(IDX) | tonumber].topics = (env(TOPICS) | fromjson)" "$REG" 2>/dev/null || true

  # Languages
  IDX="$i" LANGS="$langs_json" yq -i ".repos[env(IDX) | tonumber].languages = (env(LANGS) | fromjson)" "$REG" 2>/dev/null || true

  # License change detection
  old_spdx=$(IDX="$i" yq -r '.repos[env(IDX) | tonumber].license_current_spdx // ""' "$REG" 2>/dev/null || true)
  if [[ -n "$old_spdx" && "$old_spdx" != "$spdx" && "$old_spdx" != "null" ]]; then
    today=$(date -u +%F)
    last_sha=$(jq -r '.pushed_at // ""' "$U_JSON")
    IDX="$i" DATE="$today" OLD="$old_spdx" NEW="$spdx" SHA="$last_sha" \
      yq -i '.repos[env(IDX) | tonumber].license_history = ((.repos[env(IDX) | tonumber].license_history // []) + [{"date": strenv(DATE), "from_spdx": strenv(OLD), "to_spdx": strenv(NEW), "upstream_sha": strenv(SHA)}])' "$REG" 2>/dev/null || true
    echo "::notice::license change: $up $old_spdx -> $spdx"
  fi

  updated=$((updated + 1))
  echo "refreshed $up (stars=$stars forks=$forks)"
done

echo "metadata refreshed for $updated repo(s)"
