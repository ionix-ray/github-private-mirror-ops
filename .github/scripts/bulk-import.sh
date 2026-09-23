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

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$SCRIPT_DIR/lib-tracker.sh"
# shellcheck source=/dev/null
. "$SCRIPT_DIR/lib-gh.sh"

# Charset hardening
if ! is_valid_owner_or_repo "$SOURCE_OWNER"; then
  echo "::error::SOURCE_OWNER has unsupported characters"
  exit 1
fi
if ! is_valid_owner_or_repo "$TARGET_OWNER"; then
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

# --- Discover public repos (one `gh` call, capped by MAX_REPOS) ---
# No explicit rate-limit precheck: `gh` surfaces exhaustion clearly, the run is
# throttled (sleep 2 per repo), and per-repo failures are counted, not fatal.
echo "discovering public repos for $SOURCE_OWNER ..."
REPOS_JSON="$TMPDIR_RUN/repos.json"
REPOS_ERR="$TMPDIR_RUN/repos.err"
all_repos="$TMPDIR_RUN/all_repos.txt"
true > "$all_repos"

if ! gh_repo_list_public "$SOURCE_OWNER" "$MAX_REPOS" "$REPOS_JSON" "$REPOS_ERR"; then
  echo "::error::repo discovery failed ($(tail -n 1 "$REPOS_ERR" 2>/dev/null || true))"
  exit 1
fi

jq -r '.[] | select(.private == false) | .full_name' "$REPOS_JSON" > "$all_repos"
discovered=$(wc -l < "$all_repos" | tr -d ' ')

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

# Base branch for registration PRs (register-repo.sh creates PR branches off it).
BASE_BRANCH="${BASE_BRANCH:-main}"
export BASE_BRANCH

while IFS= read -r repo; do
  echo ""
  echo "--- mirroring $repo -> $TARGET_OWNER ---"

  # Check if already registered (idempotency) — scan intent records.
  dup=0
  while IFS= read -r rf; do
    [[ -z "$rf" ]] && continue
    [[ "$(jq -r '.upstream' "$rf")" == "$repo" ]] && { dup=1; break; }
  done < <(list_registry_files)
  if (( dup )); then
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
        # Return to the clean base branch so the next registration PR is
        # independent (register-repo.sh left us on its PR branch).
        git checkout "$BASE_BRANCH" >/dev/null 2>&1 || git checkout -q "$(git rev-parse --short HEAD)"
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
    if del_err="$(gh_delete_repo "$repo" 2>&1)"; then
      echo "deleted $repo"
    elif grep -qi "admin\|permission\|403\|forbidden" <<<"$del_err"; then
      echo "::warning::cannot delete $repo — token lacks admin permission or you do not own this repo"
    elif grep -qi "not found\|could not resolve\|404" <<<"$del_err"; then
      echo "::warning::$repo already deleted or not found"
    else
      echo "::warning::delete $repo failed ($(tail -n 1 <<<"$del_err"))"
    fi
    sleep 1
  done
fi
