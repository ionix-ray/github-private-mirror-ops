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

echo "== CASE 4: TWO BOT writers race on the SAME metadata+read-model files =="
# The old design had two bot workflows (sync-status, sync-mirrors) in DIFFERENT
# concurrency groups pushing the same files; the loser failed and lost changes.
# The fix is TWO-LAYER:
#   (a) ONE shared concurrency group serializes the bots -> they cannot overlap.
#   (b) commit-bot-changes.sh rebase-retry absorbs interleaved main writes that
#       are NOT in the bot namespace (e.g. a registration PR adding a registry file
#       while the bot rewrites metadata) -> different files, rebase merges cleanly.
# This case proves BOTH halves:
#   4a. rebase of a bot commit over a registration PR (different files) -> clean.
#   4b. two bots editing the SAME file -> rebase STILL conflicts, proving why the
#       shared concurrency group (serialization) is mandatory, not optional.
reset_tree() {  # back to a clean main
  git merge --abort >/dev/null 2>&1 || true
  git rebase --abort >/dev/null 2>&1 || true
  git checkout -q main 2>/dev/null || git checkout -q -b main 2>/dev/null || true
  git reset -q --hard main >/dev/null 2>&1 || true
}

echo "  CASE 4a: bot push rebased over a concurrent registration PR (different files -> clean)"
reset_tree
base4a=$(git rev-parse HEAD)
# bot B starts from main, rewrites ONLY metadata (bot namespace)
git checkout -q -b bot-B "$base4a"
echo '{"upstream":"a/a","private":"o/a","stargazers_count":1000,"last_synced_status":"ok","last_synced_sha":"abc"}' > tracker/metadata/o__a.json
git add -A && git commit -qm "chore: auto-sync mirrors [skip ci]"
# registration PR lands on main, adding a NEW registry file (different namespace)
git checkout -q -b reg-f "$base4a"
echo '{"upstream":"f/f","private":"o/f","branch":"main","paused":false,"pause_reason":""}' > tracker/registry/o__f.json
git add -A && git commit -qm "register f"
reset_tree
merge_clean reg-f || { note "FAIL: registration merge setup failed"; fail=1; }
# commit-bot-changes loop: rebase bot-B onto the new main (different files -> clean)
git checkout -q bot-B
if git rebase -q main >/dev/null 2>&1; then
  git checkout -q main
  if merge_clean bot-B; then
    note "OK: bot B rebased over registration PR; metadata + registry both present"
  else
    note "FAIL: bot B merge after rebase conflicted"; fail=1
  fi
else
  git rebase --abort >/dev/null 2>&1 || true
  note "FAIL: bot B rebase over registration PR conflicted"; fail=1
fi

echo "  CASE 4b: two bots editing the SAME metadata file MUST conflict (why we serialize)"
reset_tree
base4b=$(git rev-parse HEAD)
git checkout -q -b bot-A2 "$base4b"
echo '{"upstream":"a/a","private":"o/a","stargazers_count":1000,"license_current_spdx":"MIT"}' > tracker/metadata/o__a.json
git add -A && git commit -qm "bot A2 refresh"
reset_tree
merge_clean bot-A2 || { note "FAIL: bot A2 setup merge failed"; fail=1; }
# bot B2 starts from the SAME base as A2 (not from main-after-A2) — the real race
git checkout -q -b bot-B2 "$base4b"
echo '{"upstream":"a/a","private":"o/a","stargazers_count":1000,"last_synced_status":"ok","last_synced_sha":"DIFFERENT"}' > tracker/metadata/o__a.json
git add -A && git commit -qm "bot B2 refresh"
reset_tree
if merge_clean bot-B2; then
  note "UNEXPECTED: two bots merged the same file cleanly (harness cannot detect the race)"
  fail=1
else
  note "OK: same-file bot writes conflict — shared concurrency group (serialization) is mandatory"
fi
reset_tree

echo ""
if (( fail )); then echo "=== no-conflict test: FAIL ==="; exit 1; fi
echo "=== no-conflict test: PASS ==="; exit 0
