#!/usr/bin/env bash
# commit-bot-changes.sh
# The ONLY way bot workflows write to the ops repo's default branch.
#
# Conflict-free by construction + contention-safe:
#   1. Always checks out the default branch first — so a previous step that left
#      HEAD on a register/* or pause/* PR branch can NEVER leak a registry edit
#      into the main push (this closes the pause-branch leak).
#   2. Stages ONLY bot-owned paths (tracker/metadata + generated read-model),
#      never tracker/registry/* (PR/human-owned).
#   3. Pushes with a rebase-and-retry loop: if main moved since checkout (a
#      registration PR merged, or the other bot workflow pushed), it rebases onto
#      the fresh remote HEAD and retries — up to N attempts. Rebase (not merge)
#      keeps the bot commit linear; write_json_stable keeps the re-merge clean.
#
# Env: COMMIT_MESSAGE (default "chore: auto-sync [skip ci]")
#      DEFAULT_BRANCH (default "main")

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$SCRIPT_DIR/lib-tracker.sh"

COMMIT_MESSAGE="${COMMIT_MESSAGE:-chore: auto-sync [skip ci]}"
default_branch="${DEFAULT_BRANCH:-main}"
attempts="${PUSH_ATTEMPTS:-4}"

git config user.email "${GIT_AUTHOR_EMAIL:-bot@dpost.me}"
git config user.name  "${GIT_AUTHOR_NAME:-git-private-repo-manager}"

# Safety: always operate from the default branch. If we're on a PR branch left by
# register-repo.sh / sync-mirror.sh, return to base FIRST so nothing staged there
# (e.g. a registry pause edit) can ride along on the main push.
git checkout -q "$default_branch" 2>/dev/null \
  || git checkout -q -B "$default_branch" "origin/$default_branch" 2>/dev/null \
  || git checkout -q --detach 2>/dev/null || true

# Stage ONLY bot-owned paths. Deliberately NOT tracker/registry/** — the PR path
# owns intent files; if we staged them here a metadata commit could conflict with
# an open registration PR, and a pause edit could leak past review.
git add "$TRACKER_DIR/metadata" "$JSON_OUT" "$MD_OUT" "$README_OUT" 2>/dev/null || true

if git diff --cached --quiet; then
  echo "no bot-owned changes to commit"
  exit 0
fi

git commit -m "$COMMIT_MESSAGE" >/dev/null

# Push with rebase-and-retry: any interleaved main write is rebased onto, never
# force-pushed over. write_json_stable diffs make rebase merges clean.
for (( i = 1; i <= attempts; i++ )); do
  if git push origin "HEAD:$default_branch" 2>/dev/null; then
    echo "pushed bot-owned changes to $default_branch"
    exit 0
  fi
  echo "push attempt $i/$attempts rejected (main moved?) — rebasing and retrying"
  git pull --rebase origin "$default_branch" 2>/dev/null \
    || git fetch origin "$default_branch" 2>/dev/null || true
done

echo "::error::could not push bot-owned changes to $default_branch after $attempts attempts"
exit 1
