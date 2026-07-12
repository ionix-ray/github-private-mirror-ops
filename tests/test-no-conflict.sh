#!/usr/bin/env bash
# tests/test-no-conflict.sh
# Proves the write-ownership split eliminates synced-repos merge conflicts.
#
# Builds a throwaway git repo and exercises real three-way merges:
#   CONTROL   (old design): two writers edit ONE shared list file  -> MUST conflict
#                           (this proves the harness can actually detect conflicts)
#   CASE 1    two concurrent registrations (each adds a NEW file)  -> no conflict
#   CASE 2    a registration PR vs a bot metadata refresh on main  -> no conflict
#   CASE 3    a human "pause" edit vs a bot metadata refresh       -> no conflict
#
# Exit 0 only if CONTROL conflicts AND all treatment cases merge cleanly.

set -uo pipefail

WORK="$(mktemp -d -t noconflict.XXXXXXXX)"
trap 'rm -rf "$WORK"' EXIT
cd "$WORK"

git init -q
git config user.email t@t.t
git config user.name tester
git config commit.gpgsign false

fail=0
note() { printf '  %s\n' "$*"; }

merge_clean() {  # branch -> returns 0 if merged with no conflict
  git merge --no-edit "$1" >/dev/null 2>&1
  local rc=$?
  if (( rc != 0 )) || git ls-files -u | grep -q .; then
    git merge --abort >/dev/null 2>&1 || true
    return 1
  fi
  return 0
}

########################################################################
# CONTROL — the OLD design: one shared file, two independent writers.
########################################################################
echo "== CONTROL: single shared list file (old design) =="
mkdir -p oldreg
printf 'repos:\n  - a/a\n  - b/b\n' > oldreg/synced-repos.yml
git add -A && git commit -qm "control base"
base=$(git rev-parse HEAD)

# writer 1: bot rewrites the list (append + metadata churn at the tail)
git checkout -q -b control-bot
printf 'repos:\n  - a/a  # stars=10\n  - b/b  # stars=20\n' > oldreg/synced-repos.yml
git commit -qam "control bot refresh"

# writer 2: a registration appends a new entry at the tail
git checkout -q "$base"
git checkout -q -b control-register
printf 'repos:\n  - a/a\n  - b/b\n  - c/c\n' > oldreg/synced-repos.yml
git commit -qam "control register c/c"

git checkout -q control-bot
if merge_clean control-register; then
  note "UNEXPECTED: control merged cleanly (harness would not detect real conflicts)"; fail=1
else
  note "OK: control conflicts as expected (harness detects conflicts)"
fi

########################################################################
# Treatment cases — the NEW design: per-record files, disjoint owners.
########################################################################
git checkout -q --orphan main
git rm -rfq . 2>/dev/null || true
mkdir -p tracker/registry tracker/metadata
echo '{"upstream":"a/a","private":"o/a","branch":"main","paused":false,"pause_reason":""}' > tracker/registry/o__a.json
echo '{"upstream":"b/b","private":"o/b","branch":"main","paused":false,"pause_reason":""}' > tracker/registry/o__b.json
echo '{"upstream":"a/a","private":"o/a","stargazers_count":1}' > tracker/metadata/o__a.json
echo '{"upstream":"b/b","private":"o/b","stargazers_count":2}' > tracker/metadata/o__b.json
git add -A && git commit -qm "new-design base"
newbase=$(git rev-parse HEAD)

echo "== CASE 1: two concurrent registrations (new files) =="
git checkout -q -b reg-c
echo '{"upstream":"c/c","private":"o/c","branch":"main","paused":false,"pause_reason":""}' > tracker/registry/o__c.json
git add -A && git commit -qm "register c"
git checkout -q "$newbase"; git checkout -q -b reg-d
echo '{"upstream":"d/d","private":"o/d","branch":"main","paused":false,"pause_reason":""}' > tracker/registry/o__d.json
git add -A && git commit -qm "register d"
git checkout -q main
if merge_clean reg-c && merge_clean reg-d; then
  note "OK: both registrations merged cleanly"
else
  note "FAIL: concurrent registrations conflicted"; fail=1
fi

echo "== CASE 2: registration PR vs bot metadata refresh on main =="
tip=$(git rev-parse HEAD)
git checkout -q -b reg-e "$tip"
echo '{"upstream":"e/e","private":"o/e","branch":"main","paused":false,"pause_reason":""}' > tracker/registry/o__e.json
git add -A && git commit -qm "register e"
git checkout -q main
# bot refresh: rewrite ALL metadata files + read-model (high churn) — intent untouched
echo '{"upstream":"a/a","private":"o/a","stargazers_count":111}' > tracker/metadata/o__a.json
echo '{"upstream":"b/b","private":"o/b","stargazers_count":222}' > tracker/metadata/o__b.json
echo '{"generated_at":"now","repos":[]}' > repo-status.json
git add -A && git commit -qm "chore: auto-sync [skip ci]"
if merge_clean reg-e; then
  note "OK: registration merged cleanly over a bot refresh"
else
  note "FAIL: registration conflicted with bot refresh"; fail=1
fi

echo "== CASE 3: human pause edit vs bot metadata refresh =="
tip=$(git rev-parse HEAD)
git checkout -q -b pause-a "$tip"
echo '{"upstream":"a/a","private":"o/a","branch":"main","paused":true,"pause_reason":"upstream unstable"}' > tracker/registry/o__a.json
git add -A && git commit -qm "pause o/a"
git checkout -q main
echo '{"upstream":"a/a","private":"o/a","stargazers_count":999}' > tracker/metadata/o__a.json
git add -A && git commit -qm "chore: auto-sync [skip ci]"
if merge_clean pause-a; then
  note "OK: human pause edit merged cleanly over a bot refresh"
else
  note "FAIL: pause edit conflicted with bot refresh"; fail=1
fi

echo ""
if (( fail )); then echo "=== no-conflict test: FAIL ==="; exit 1; fi
echo "=== no-conflict test: PASS ==="; exit 0
