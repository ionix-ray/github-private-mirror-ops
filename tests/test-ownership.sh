#!/usr/bin/env bash
# tests/test-ownership.sh
# Verifies the write-ownership guard and the pause-branch leak fix:
#   1. guard-ownership.sh rejects PRs touching bot-owned files
#      (tracker/metadata, repo-status.json, REPO_STATUS.md, README.md)
#      and allows PRs that only add intent (tracker/registry/*)
#   2. commit-bot-changes.sh returns to the default branch before pushing, so a
#      pause/* or register/* branch left over by an earlier step cannot leak a
#      registry edit into the main push.

set -uo pipefail
ROOT="$(git rev-parse --show-toplevel)" || { echo "must run inside git repo"; exit 2; }

fail=0
note() { printf '  %s\n' "$*"; }

echo "== 1. ownership guard predicates (offline, no git) =="
# run guard-ownership.sh feeding changed-file lists via stdin

out="$(printf 'tracker/registry/o__x.json\n' | bash "$ROOT/.github/scripts/guard-ownership.sh")"
rc=$?
if (( rc == 0 )); then note "PASS  registry-only PR allowed"; else note "FAIL  registry-only PR rejected (rc=$rc)"; fail=1; fi

for guarded in "tracker/metadata/o__x.json" "repo-status.json" "REPO_STATUS.md" "README.md" "tracker/metadata/deep/o.json"; do
  out="$(printf '%s\n' "$guarded" | bash "$ROOT/.github/scripts/guard-ownership.sh")"
  rc=$?
  if (( rc != 0 )); then note "PASS  '$guarded' rejected"; else note "FAIL  '$guarded' allowed"; fail=1; fi
done

# mixed: intent + generated -> must fail (generated file present)
out="$(printf 'tracker/registry/o__y.json\nrepo-status.json\n' | bash "$ROOT/.github/scripts/guard-ownership.sh")"
rc=$?
if (( rc != 0 )); then note "PASS  mixed PR (intent + generated) rejected"; else note "FAIL  mixed PR allowed"; fail=1; fi

echo "== 2. pause-branch leak: commit-bot-changes.sh must not push registry edits =="
WORK="$(mktemp -d -t ownship.XXXXXXXX)"
trap 'rm -rf "$WORK"' EXIT
cd "$WORK"
git init -q -b main
git config user.email t@t.t
git config user.name tester
git config commit.gpgsign false
mkdir -p tracker/registry tracker/metadata
echo '{"upstream":"a/a","private":"o/a","branch":"main","paused":false,"pause_reason":""}' > tracker/registry/o__a.json
echo '{}' > tracker/metadata/o__a.json
git add -A && git commit -qm base

# Simulate sync-mirror.sh leaving HEAD on a pause/* branch with an uncommitted
# registry edit staged (the old leak). commit-bot-changes.sh must:
#   - checkout main (discarding the staged registry edit)
#   - stage + commit only bot-owned files
#   - never include tracker/registry/* in the commit
git checkout -q -b pause/o__a-20260809
echo '{"upstream":"a/a","private":"o/a","branch":"main","paused":true,"pause_reason":"diverged"}' > tracker/registry/o__a.json
git add tracker/registry/o__a.json          # staged registry edit on pause branch
echo '{"upstream":"a/a","last_synced_status":"ok"}' > tracker/metadata/o__a.json

# Run commit-bot-changes.sh. Point TRACKER_DIR at our repo; JSON_OUT/MD_OUT/README_OUT
# must exist or be handled. It will git add them (missing is fine), then commit.
# We intercept the push: no remote, so set DEFAULT_BRANCH and expect the rebase
# loop to fail, but we only care about what was STAGED/COMMITTED before push.
TRACKER_DIR=tracker JSON_OUT=repo-status.json MD_OUT=REPO_STATUS.md README_OUT=README.md \
  DEFAULT_BRANCH=main PUSH_ATTEMPTS=1 \
  bash "$ROOT/.github/scripts/commit-bot-changes.sh" >/dev/null 2>&1 || true

if git diff HEAD --name-only | grep -q 'tracker/registry/'; then
  note "FAIL  registry edit leaked into the bot commit"
  fail=1
else
  note "PASS  registry edit did NOT leak into the bot commit"
fi
if git diff HEAD --name-only | grep -q 'tracker/metadata/'; then
  note "PASS  bot-owned metadata change committed"
else
  note "FAIL  metadata change missing from bot commit"
  fail=1
fi

echo ""
if (( fail )); then echo "=== ownership test: FAIL ==="; exit 1; fi
echo "=== ownership test: PASS ==="
exit 0
