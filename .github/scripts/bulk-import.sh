#!/usr/bin/env bash
# bulk-import.sh
# Bulk discovers all public repos from a source owner and mirrors them privately.
# Reuses mirror-clone-push.sh and register-repo.sh for each repo.
# Supports dry-run (default), rate-limit checks, max repo cap.
# Delete original repos only if confirmation_phrase matches exactly.
#
# Env: SOURCE_OWNER (required), TARGET_OWNER (required), GH_TOKEN (required)
#      BRANCH_INPUT (optional, default ""), MAX_REPOS (default 50)
#      DRY_RUN (default true), DELETE_ORIGINAL (default false)
#      CONFIRMATION_PHRASE (default ""), GITHUB_REPOSITORY (required)

set -euo pipefail

readonly REQUIRED_DELETE_PHRASE="DELETE_ORIGINAL_REPOS"

: "${SOURCE_OWNER:?}" || { echo "::error::SOURCE_OWNER required"; exit 1; }
: "${TARGET_OWNER:?}" || { echo "::error::TARGET_OWNER required"; exit 1; }
: "${GH_TOKEN:?}"     || { echo "::error::GH_TOKEN required"; exit 1; }
: "${GITHUB_REPOSITORY:?}" || { echo "::error::GITHUB_REPOSITORY required"; exit 1; }

BRANCH_INPUT="${BRANCH_INPUT:-}"
MAX_REPOS="${MAX_REPOS:-50}"
DRY_RUN="${DRY_RUN:-true}"
DELETE_ORIGINAL="${DELETE_ORIGINAL:-false}"
CONFIRMATION_PHRASE="${CONFIRMATION_PHRASE:-}"
REG="${REG:-.github/synced-repos.yml}"

# Charset hardening
if ! [[ "$SOURCE_OWNER" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,99}$ ]]; then
  echo "::error::SOURCE_OWNER has unsupported characters"
  exit 1
fi
if ! [[ "$TARGET_OWNER" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,99}$ ]]; then
  echo "::error::TARGET_OWNER has unsupported characters"
  exit 1
fi
if ! [[ "$MAX_REPOS" =~ ^[0-9]+$ ]] || (( MAX_REPOS > 200 )); then
  echo "::error::MAX_REPOS must be 0-200"
  exit 1
fi

TMPDIR_RUN="$(mktemp -d -t bulk.XXXXXXXX)"
trap 'rm -rf "$TMPDIR_RUN"' EXIT
chmod 0700 "$TMPDIR_RUN"

# --- Rate limit sanity check ---
RATELIMIT_JSON="$TMPDIR_RUN/ratelimit.json"
rl=$(curl -sS -o "$RATELIMIT_JSON" -w '%{http_code}'   -H "Accept: application/vnd.github+json"   -H "Authorization: Bearer ${GH_TOKEN}"   -H "X-GitHub-Api-Version: 2022-11-28"   "https://api.github.com/rate_limit")
if [[ "$rl" == "200" ]]; then
  remaining=$(jq -r '.resources.core.remaining // 0' "$RATELIMIT_JSON")
  # Need at least 3 API calls per repo (list + check exists + create + push + register)
  # Plus initial rate limit call
  min_needed=$((MAX_REPOS * 5 + 10))
  if (( remaining < min_needed )); then
    echo "::error::rate limit too low ($remaining remaining, need ~$min_needed). Wait or reduce MAX_REPOS."
    exit 1
  fi
  echo "rate limit OK: $remaining remaining (need ~$min_needed)"
else
  echo "::warning::could not check rate limit (HTTP $rl) — proceeding anyway"
fi

# --- Discover public repos via pagination ---
echo "discovering public repos for $SOURCE_OWNER ..."
REPOS_JSON="$TMPDIR_RUN/repos.json"
page=1
per_page=100
all_repos="$TMPDIR_RUN/all_repos.txt"
true > "$all_repos"

discovered=0
while (( discovered < MAX_REPOS )); do
  http=$(curl -sS -o "$REPOS_JSON" -w '%{http_code}'     -H "Accept: application/vnd.github+json"     -H "Authorization: Bearer ${GH_TOKEN}"     -H "X-GitHub-Api-Version: 2022-11-28"     "https://api.github.com/users/${SOURCE_OWNER}/repos?type=public&per_page=${per_page}&page=${page}")

  if [[ "$http" != "200" ]]; then
    msg=$(jq -r '.message // ""' "$REPOS_JSON" 2>/dev/null || true)
    echo "::error::repo discovery failed (HTTP $http): $msg"
    exit 1
  fi

  count_this_page=$(jq 'length' "$REPOS_JSON")
  if (( count_this_page == 0 )); then
    break
  fi

  jq -r '.[] | select(.private == false or .visibility == "public") | .full_name' "$REPOS_JSON" >> "$all_repos"
  discovered=$(wc -l < "$all_repos" | tr -d ' ')

  if (( count_this_page < per_page )); then
    break
  fi
  page=$((page + 1))
  # Throttle discovery to avoid burning rate limit early
  sleep 1
done

# Truncate to MAX_REPOS
discovered=$(wc -l < "$all_repos" | tr -d ' ')
if (( discovered > MAX_REPOS )); then
  head -n "$MAX_REPOS" "$all_repos" > "${all_repos}.tmp"
  mv "${all_repos}.tmp" "$all_repos"
  discovered=$MAX_REPOS
fi

if (( discovered == 0 )); then
  echo "no public repos found for $SOURCE_OWNER"
  exit 0
fi

echo "found $discovered public repo(s) to mirror"

# Show discovery list
cat "$all_repos" | while IFS= read -r repo; do
  echo "  - $repo"
done

if [[ "$DRY_RUN" == "true" ]]; then
  echo ""
  echo "::notice::DRY RUN active. Pass dry_run=false to perform actual mirroring."
  exit 0
fi

# --- Mirror each repo ---
mirrored=0
skipped=0
failed=0
failed_repos="$TMPDIR_RUN/failed.txt"
true > "$failed_repos"

delete_list="$TMPDIR_RUN/delete_list.txt"
true > "$delete_list"

while IFS= read -r repo; do
  echo ""
  echo "--- mirroring $repo -> $TARGET_OWNER ---"

  # Check if already registered (idempotency)
  dup=$(UP="$repo" yq -r '.repos | map(select(.upstream == strenv(UP))) | length' "$REG")
  if [[ "$dup" != "0" ]]; then
    echo "already registered — skip"
    skipped=$((skipped + 1))
    continue
  fi

  # Set up env for mirror-clone-push.sh
  export PUBLIC_URL="https://github.com/${repo}.git"
  export TARGET_OWNER
  export BRANCH_INPUT
  export PRIVATE_NAME_INPUT=""
  export GH_TOKEN

  # Single call with temp GITHUB_OUTPUT so we can read results
  OUTFILE="$TMPDIR_RUN/output_$(echo "$repo" | tr '/' '_').txt"

  if GITHUB_OUTPUT="$OUTFILE" bash .github/scripts/mirror-clone-push.sh; then
    mirrored=$((mirrored + 1))
    echo "mirror successful"

    up_f=""
    pr_f=""
    br=""
    if [[ -f "$OUTFILE" ]]; then
      up_f=$(grep '^upstream_full=' "$OUTFILE" | cut -d= -f2- || true)
      pr_f=$(grep '^private_full='  "$OUTFILE" | cut -d= -f2- || true)
      br=$(grep '^branch='          "$OUTFILE" | cut -d= -f2- || true)
    fi

    if [[ -n "$up_f" && -n "$pr_f" && -n "$br" ]]; then
      export UPSTREAM_FULL="$up_f"
      export PRIVATE_FULL="$pr_f"
      export BRANCH="$br"
      if bash .github/scripts/register-repo.sh; then
        echo "registered $up_f -> $pr_f"
      else
        echo "::warning::registration failed for $repo"
      fi
    else
      echo "::warning::could not determine mirror outputs for $repo"
    fi

    # If delete_original requested, add to delete list (API will 403 if we do not own it)
    if [[ "$DELETE_ORIGINAL" == "true" ]]; then
      echo "$repo" >> "$delete_list"
    fi
  else
    echo "::warning::mirror failed for $repo"
    failed=$((failed + 1))
    echo "$repo" >> "$failed_repos"
  fi

  sleep 2  # throttle between repos
done < "$all_repos"

echo ""
echo "=== Bulk Import Summary ==="
echo "discovered: $discovered  mirrored: $mirrored  skipped: $skipped  failed: $failed"

if (( failed > 0 )); then
  echo "failed repos:"
  cat "$failed_repos" | while IFS= read -r repo; do
    echo "  - $repo"
  done
fi

if [[ "$DELETE_ORIGINAL" == "true" && -s "$delete_list" ]]; then
  echo ""
  echo "::warning::DELETE_ORIGINAL requested. Manual intervention required."

  # Verify confirmation phrase
  if [[ "$CONFIRMATION_PHRASE" != "$REQUIRED_DELETE_PHRASE" ]]; then
    echo "::error::delete_original=true but confirmation_phrase does not match '$REQUIRED_DELETE_PHRASE'. Skipping deletion."
    echo "To delete original repos, run again with:"
    echo "  delete_original=true"
    echo "  confirmation_phrase=$REQUIRED_DELETE_PHRASE"
    exit 0
  fi

  # Double-check that we actually own these repos before deleting
  echo ""
  echo "--- Deleting original public repos ---"
  cat "$delete_list" | while IFS= read -r repo; do
    echo "deleting $repo ..."
    del_http=$(curl -sS -o /dev/null -w '%{http_code}' -X DELETE       -H "Accept: application/vnd.github+json"       -H "Authorization: Bearer ${GH_TOKEN}"       -H "X-GitHub-Api-Version: 2022-11-28"       "https://api.github.com/repos/${repo}")
    if [[ "$del_http" == "204" ]]; then
      echo "deleted $repo"
    elif [[ "$del_http" == "403" ]]; then
      echo "::warning::cannot delete $repo (403) — token lacks admin permission or you do not own this repo"
    elif [[ "$del_http" == "404" ]]; then
      echo "::warning::$repo already deleted or not found (404)"
    else
      echo "::warning::delete $repo returned HTTP $del_http"
    fi
    sleep 1
  done
fi
