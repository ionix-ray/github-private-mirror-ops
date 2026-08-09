#!/usr/bin/env bash
# guard-ownership.sh
# Enforces write ownership on a PR: the bot-owned namespace (tracker/metadata +
# generated read-model) must ONLY change via the bot workflows. A PR that edits
# those files is a merge-conflict / invariant risk (a human write racing the bot,
# or a hand-edit that the bot will overwrite), so the guard fails the PR.
#
# Reads the list of changed files from STDIN (one per line) or GIT_IS_NEEDED.
# Env: NONE. Pure predicate — safe offline. Exit 0 = ok, 1 = guarded files touched.
#
# Usage:
#   git diff --name-only origin/main...HEAD | bash .github/scripts/guard-ownership.sh

set -uo pipefail

# Bot-owned: written only by sync workflows. Registry (intent) is PR/human-owned
# and deliberately NOT guarded — registration PRs add new registry files.
BOT_OWNED_PATTERNS=(
  '^tracker/metadata/'
  '^repo-status\.json$'
  '^REPO_STATUS\.md$'
  '^README\.md$'
)

files=()
while IFS= read -r line; do
  [[ -n "$line" ]] && files+=("$line")
done

# When invoked with no stdin (e.g. git diff produced nothing), still guard.
if (( ${#files[@]} == 0 )) && [[ -n "${CHANGED_FILES:-}" ]]; then
  IFS=$'\n' read -r -d '' -a files <<< "$CHANGED_FILES" || true
fi

violations=()
for f in "${files[@]}"; do
  for pat in "${BOT_OWNED_PATTERNS[@]}"; do
    if [[ "$f" =~ $pat ]]; then
      violations+=("$f")
      break
    fi
  done
done

if (( ${#violations[@]} > 0 )); then
  echo "::error::bot-owned files must not be edited in a PR (the sync bot owns them):"
  printf '  %s\n' "${violations[@]}"
  echo "Revert these changes and let the Sync Status / Sync Mirrors workflows update them."
  exit 1
fi

echo "ownership guard: OK (no bot-owned files touched)"
exit 0
