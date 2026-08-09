#!/usr/bin/env bash
# sync-mirrors.sh
# Orchestrator for sync-mirror.sh — runs once per registry record.
#
#   Env: GH_TOKEN, GITHUB_REPOSITORY, TARGET_OWNER (optional filter),
#        PAUSE_REPO, OPEN_ISSUE
#
# Skips paused mirrors (they stay paused until a human unpauses). After the loop,
# regenerates the read-model so repo-status.json / REPO_STATUS.md / README.md
# reflect the new last_synced_* fields. Commits happen in the workflow.

set -euo pipefail

: "${GH_TOKEN:?}"
: "${GITHUB_REPOSITORY:?}"
TARGET_OWNER="${TARGET_OWNER:-}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$SCRIPT_DIR/lib-tracker.sh"

mapfile -t reg_files < <(list_registry_files)
(( ${#reg_files[@]} == 0 )) && { echo "no intent records — skip"; exit 0; }

synced=0 skipped=0 failed=0
for rf in "${reg_files[@]}"; do
  up=$(jq -r '.upstream' "$rf")
  pr=$(jq -r '.private'  "$rf")
  br=$(jq -r '.branch // "main"' "$rf")
  paused=$(jq -r '.paused // false' "$rf")

  if [[ "$paused" == "true" ]]; then
    echo "skip (paused): $pr"
    skipped=$((skipped + 1))
    continue
  fi
  if [[ -n "$TARGET_OWNER" ]]; then
    pr_owner="${pr%%/*}"
    if [[ "$pr_owner" != "$TARGET_OWNER" ]]; then
      echo "skip (owner filter): $pr"
      skipped=$((skipped + 1))
      continue
    fi
  fi

  if UPSTREAM_FULL="$up" PRIVATE_FULL="$pr" BRANCH="$br" \
      PAUSE_REPO="${PAUSE_REPO:-true}" OPEN_ISSUE="${OPEN_ISSUE:-true}" \
      bash "$SCRIPT_DIR/sync-mirror.sh"; then
    synced=$((synced + 1))
  else
    echo "sync failed (exit $?): $pr"
    failed=$((failed + 1))
  fi
done

echo "sync complete: $synced synced, $skipped skipped, $failed failed"

# Regenerate the read-model from the updated metadata.
bash "$SCRIPT_DIR/generate-json.sh"
bash "$SCRIPT_DIR/generate-md.sh"
bash "$SCRIPT_DIR/render-readme.sh"

exit 0
