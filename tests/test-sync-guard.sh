#!/usr/bin/env bash
# tests/test-sync-guard.sh
# Regression tests for the sync divergence-noise fix (offline, no GH_TOKEN):
#   1. git_ancestry_check reports upstream_ahead (not diverged) for a clean
#      fast-forward, equal for identical SHAs, private_ahead, and diverged for
#      truly forked histories.
#   2. git_ff_private fast-forwards the private ref with a pure (non-force)
#      SHA push — the old code pushed the caller's local branch ref, so FF
#      never succeeded and every behind mirror was misreported as diverged.
#   3. git_push_private ff-only refuses (must go through git_ff_private).
#   4. divergence_issue_exists / pause_pr_exists match open items so the daily
#      cron cannot open a duplicate issue or timestamped pause branch per run.
#
# Uses GIT_BASE_URL pointed at local bare repos (no network).

set -uo pipefail
ROOT="$(git rev-parse --show-toplevel)" || { echo "must run inside git repo"; exit 2; }
# shellcheck source=/dev/null
source "$ROOT/.github/scripts/lib-gh.sh"

fail=0
note() { printf '  %s\n' "$*"; }
check() { # desc expected actual
  if [[ "$2" == "$3" ]]; then note "PASS  $1";
  else note "FAIL  $1 (expected '$2', got '$3')"; fail=1; fi
}

WORK="$(mktemp -d -t syncguard.XXXXXXXX)"
trap 'rm -rf "$WORK"' EXIT
cd "$WORK" || exit 2
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t.t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t.t

# --- Build local "upstream" history A -> B, and a "private" mirror at A ---
git init -q -b main upstream-src
echo one > upstream-src/f.txt
git -C upstream-src add -A && git -C upstream-src commit -qm A
SHA_A="$(git -C upstream-src rev-parse HEAD)"
echo two > upstream-src/f.txt
git -C upstream-src add -A && git -C upstream-src commit -qm B
SHA_B="$(git -C upstream-src rev-parse HEAD)"

mkdir -p repos/up repos/priv
git init -q -b main --bare repos/up/repo.git
git init -q -b main --bare repos/priv/repo.git
git -C upstream-src push -q "$WORK/repos/up/repo.git" HEAD:refs/heads/main
git -C upstream-src push -q "$WORK/repos/priv/repo.git" "$SHA_A:refs/heads/main"

export GIT_BASE_URL="$WORK/repos"
export GIT_TERMINAL_PROMPT=0

echo "== 1. ancestry: behind mirror is upstream_ahead, not diverged =="
got="$(git_ancestry_check "up/repo" "priv/repo" "$SHA_B" "$SHA_A" "$WORK/w1")"
check "upstream_ahead for clean FF" "upstream_ahead" "$got"

echo "== 2. ancestry: equal / private_ahead / diverged =="
got="$(git_ancestry_check "up/repo" "priv/repo" "$SHA_A" "$SHA_A" "$WORK/w2")"
check "equal SHAs" "equal" "$got"
# private_ahead: push B to private, then compare up=A pr=B.
git -C upstream-src push -q "$WORK/repos/priv/repo.git" "$SHA_B:refs/heads/main"
got="$(git_ancestry_check "up/repo" "priv/repo" "$SHA_A" "$SHA_B" "$WORK/w3")"
check "private_ahead" "private_ahead" "$got"
# diverged: private gets C stacked on A while upstream sits on B
git -C upstream-src checkout -q "$SHA_A"
echo fork > upstream-src/f.txt
git -C upstream-src add -A && git -C upstream-src commit -qm C-fork
SHA_C="$(git -C upstream-src rev-parse HEAD)"
git -C upstream-src push -q "$WORK/repos/priv/repo.git" "$SHA_C:refs/heads/main" --force
git -C upstream-src checkout -q main 2>/dev/null || git -C upstream-src checkout -q "$SHA_B"
got="$(git_ancestry_check "up/repo" "priv/repo" "$SHA_B" "$SHA_C" "$WORK/w4")"
check "diverged for forked history" "diverged" "$got"

echo "== 3. git_ff_private fast-forwards a behind mirror (no force) =="
git -C upstream-src push -q "$WORK/repos/priv/repo.git" "$SHA_A:refs/heads/main" --force
if git_ff_private "up/repo" "priv/repo" "main" "$SHA_B" "$WORK/w5" >/dev/null 2>&1; then
  now="$(git ls-remote "$WORK/repos/priv/repo.git" refs/heads/main | awk '{print $1}')"
  check "private ref now at upstream SHA" "$SHA_B" "$now"
else
  note "FAIL  git_ff_private exited non-zero"; fail=1
fi

echo "== 4. git_ff_private refuses on diverged history (no overwrite) =="
git -C upstream-src push -q "$WORK/repos/priv/repo.git" "$SHA_C:refs/heads/main" --force
if git_ff_private "up/repo" "priv/repo" "main" "$SHA_B" "$WORK/w6" >/dev/null 2>&1; then
  note "FAIL  ff push over diverged history succeeded (would need force)"; fail=1
else
  note "PASS  ff push over diverged history refused"
fi
now="$(git ls-remote "$WORK/repos/priv/repo.git" refs/heads/main | awk '{print $1}')"
check "diverged private ref untouched" "$SHA_C" "$now"

echo "== 5. git_push_private ff-only refuses (must use git_ff_private) =="
if git_push_private "o/p" "main" "ff-only" >/dev/null 2>&1; then
  note "FAIL  legacy ff-only mode pushed"; fail=1
else
  note "PASS  legacy ff-only mode refused"
fi

echo "== 5b. SHA validation =="
if is_sha "$SHA_B"; then note "PASS  full SHA accepted"; else note "FAIL  full SHA rejected"; fail=1; fi
if is_sha "abc1234"; then note "PASS  abbreviated SHA accepted"; else note "FAIL  abbreviated SHA rejected"; fail=1; fi
for bad in "" "xyz" "refs/heads/main" "d21c0d08;rm -rf /" "D21C0D08EF9500901FDA7C4DEEC1C7CACF0781CC"; do
  if is_sha "$bad"; then note "FAIL  malformed SHA accepted: '$bad'"; fail=1; fi
done
note "PASS  malformed SHAs rejected"
if git_ff_private "up/repo" "priv/repo" "main" "not-a-sha!!" "$WORK/w5b" >/dev/null 2>&1; then
  note "FAIL  ff push accepted malformed SHA"; fail=1
else
  note "PASS  ff push refused malformed SHA"
fi

echo "== 6. dedup: existing open issue / pause PR detected, absent ones missed =="
# Stub the network layer: gh_api answers from fixtures.
ISSUE_JSON='[{"number":1,"title":"Mirror diverged: ionix-ray/wgpu","pull_request":null},{"number":2,"title":"Some PR","pull_request":{"url":"x"}}]'
PR_JSON='[{"number":7,"title":"pause: ionix-ray/wgpu (diverged)","head":{"ref":"pause/ionix-ray-wgpu-20260921070000"}}]'
gh_api() { # METHOD URL BODY -> fixture + 200, single page
  case "$2" in
    */issues*) printf '%s' "$ISSUE_JSON" > "$3" ;;
    */pulls*)  printf '%s' "$PR_JSON" > "$3" ;;
  esac
  echo 200
}
if divergence_issue_exists "o/ops" "Mirror diverged: ionix-ray/wgpu"; then
  note "PASS  existing divergence issue detected"
else
  note "FAIL  existing divergence issue missed"; fail=1
fi
if divergence_issue_exists "o/ops" "Mirror diverged: ionix-ray/nonexistent"; then
  note "FAIL  phantom issue reported as existing"; fail=1
else
  note "PASS  absent issue correctly missed"
fi
if pause_pr_exists "o/ops" "ionix-ray/wgpu"; then
  note "PASS  existing pause PR detected"
else
  note "FAIL  existing pause PR missed"; fail=1
fi
if pause_pr_exists "o/ops" "ionix-ray/nonexistent"; then
  note "FAIL  phantom pause PR reported as existing"; fail=1
else
  note "PASS  absent pause PR correctly missed"
fi

echo "== 7. close_divergence_issues closes exact-title bot issues only =="
gh_api() { # serve one page: 2 bot issues (one is really a PR), 1 unrelated
  printf '%s' '[{"number":11,"title":"Mirror diverged: ionix-ray/wgpu"},{"number":12,"title":"Mirror diverged: ionix-ray/wgpu","pull_request":{"url":"x"}},{"number":13,"title":"Something else"}]' > "$3"
  echo 200
}
# shellcheck disable=SC2317
curl_gh() { printf '%s\n' "CURLGH $*" >> "$WORK/calls"; echo 200; }
: > "$WORK/calls"
close_divergence_issues "o/ops" "ionix-ray/wgpu" "test reason" >/dev/null
if grep -q "issues/11/comments" "$WORK/calls" && grep -q "issues/11" "$WORK/calls"; then
  note "PASS  bot issue #11 commented + closed"
else
  note "FAIL  bot issue #11 not closed"; fail=1
fi
if grep -q "issues/12" "$WORK/calls"; then
  note "FAIL  PR #12 touched (must skip pull requests)"; fail=1
else
  note "PASS  pull request #12 untouched"
fi
if grep -q "issues/13" "$WORK/calls"; then
  note "FAIL  unrelated issue #13 touched"; fail=1
else
  note "PASS  unrelated issue #13 untouched"
fi

echo "== 8. anchored head match: siblings do not collide; errors fail closed =="
gh_api() { # one pause PR for cli-foo only (head shape + title)
  printf '%s' '[{"number":21,"title":"pause: ionix-ray/cli-foo (diverged)","head":{"ref":"pause/ionix-ray-cli-foo-20260921070000"}}]' > "$3"
  echo 200
}
if pause_pr_exists "o/ops" "ionix-ray/cli-foo"; then
  note "PASS  sibling pause PR detected"
else
  note "FAIL  sibling pause PR missed"; fail=1
fi
if pause_pr_exists "o/ops" "ionix-ray/cli"; then
  note "FAIL  cli false-positived on cli-foo branch"; fail=1
else
  note "PASS  no dash-prefix collision on sibling"
fi
gh_api() { echo 000; return 1; } # total API outage
if divergence_issue_exists "o/ops" "Mirror diverged: ionix-ray/wgpu" >/dev/null 2>&1; then rc=0; else rc=$?; fi
if (( rc == 2 )); then note "PASS  issue lookup error returns 2"; else note "FAIL  issue lookup rc=$rc (want 2)"; fail=1; fi
if pause_pr_exists "o/ops" "ionix-ray/wgpu" >/dev/null 2>&1; then rc=0; else rc=$?; fi
if (( rc == 2 )); then note "PASS  PR lookup error returns 2"; else note "FAIL  PR lookup rc=$rc (want 2)"; fail=1; fi

echo ""
if (( fail )); then echo "=== sync-guard test: FAIL ==="; exit 1; fi
echo "=== sync-guard test: PASS ==="
exit 0
