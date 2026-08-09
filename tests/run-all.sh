#!/usr/bin/env bash
# tests/run-all.sh — full offline test suite (no network, no GH_TOKEN).
#   1. schema fixtures
#   2. live registry + metadata validate against schemas
#   3. read-model generation (generate-json + generate-md + render-readme)
#   4. merge-conflict simulation (the core guarantee)

set -uo pipefail
cd "$(git rev-parse --show-toplevel)"
rc=0
run() { echo ""; echo "### $1"; bash "$2" || { echo "!! $1 FAILED"; rc=1; }; }

echo "### 1. schema fixtures"
bash tests/run-schema-tests.sh || rc=1

echo ""
echo "### 2. validate live tracker records"
bash .github/scripts/validate-registry.sh || rc=1

echo ""
echo "### 3. read-model generation (offline)"
bash .github/scripts/generate-json.sh || rc=1
bash .github/scripts/generate-md.sh   || rc=1
bash .github/scripts/render-readme.sh || rc=1
python3 -c "import json; d=json.load(open('repo-status.json')); assert d['summary']['total_repos']==len(d['repos']); print('read-model OK:', d['summary']['total_repos'], 'repo(s)')" || rc=1

run "4. merge-conflict simulation" tests/test-no-conflict.sh
run "5. lib-gh helpers" tests/test-lib-gh.sh
run "6. owner config + dropdown drift" tests/test-owners.sh
run "7. ownership guard + pause-branch leak" tests/test-ownership.sh

echo ""
if (( rc )); then echo "==== SUITE: FAIL ===="; else echo "==== SUITE: PASS ===="; fi
exit $rc
