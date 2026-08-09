#!/usr/bin/env bash
# sync-mirror.sh
# Sync ONE private mirror to its upstream using fast-forward only.
#
#   Env: UPSTREAM_FULL, PRIVATE_FULL, BRANCH, GH_TOKEN, GITHUB_REPOSITORY
#        PAUSE_REPO (default "true" — open an auto-pause PR on divergence)
#        OPEN_ISSUE (default "true" — open a divergence issue)
#
# Behaviour:
#   * Equal SHAs            -> last_synced_status "ok"
#   * Private ahead (FF)    -> fast-forward push upstream SHA into private
#   * Upstream ahead (FF)   -> private already has upstream work (ok/skipped)
#   * Diverged              -> never force-push: last_synced_status "diverged",
#                              create a GitHub issue, and open an auto-pause PR
#                              that sets paused=true on the intent record.
#
# Writes ONLY tracker/metadata/* (bot-owned) + the divergence issue/PR via API.
# Never writes tracker/registry/* on main — auto-pause goes through a PR, keeping
# the intent path human/PR-owned and conflict-free.

set -euo pipefail

: "${UPSTREAM_FULL:?}"
: "${PRIVATE_FULL:?}"
: "${BRANCH:?}"
: "${GH_TOKEN:?}"
: "${GITHUB_REPOSITORY:?}"
PAUSE_REPO="${PAUSE_REPO:-true}"
OPEN_ISSUE="${OPEN_ISSUE:-true}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$SCRIPT_DIR/lib-tracker.sh"
# shellcheck source=/dev/null
. "$SCRIPT_DIR/lib-gh.sh"

is_full_repo  "$UPSTREAM_FULL"  || { echo "::error::UPSTREAM_FULL invalid"; exit 1; }
is_full_repo  "$PRIVATE_FULL"   || { echo "::error::PRIVATE_FULL invalid"; exit 1; }
is_valid_branch "$BRANCH"       || { echo "::error::BRANCH invalid: $BRANCH"; exit 1; }

mkdir -p "$META_DIR"
key="$(tracker_key "$PRIVATE_FULL")"
mf="$META_DIR/$key.json"
now_iso="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# Shared hardening helpers (same code path as mirror-clone-push.sh).
git_setup_auth "sync"

UP_SHA=""
PR_SHA=""

write_status() { # status sha
  local status="$1" sha="$2"
  { [[ -f "$mf" ]] && cat "$mf" || jq -nc --arg up "$UPSTREAM_FULL" --arg pr "$PRIVATE_FULL" '{upstream:$up,private:$pr}'; } \
    | jq --arg s "$status" --arg sha "$sha" --arg us "$UP_SHA" --arg ts "$now_iso" \
        '.last_synced_status=$s | .last_synced_sha=$sha | .last_upstream_sha=$us | .last_synced_at=$ts | .refreshed_at=$ts' \
    | write_json_stable "$mf"
}

log(){ echo "[$UPSTREAM_FULL -> $PRIVATE_FULL] $*"; }

# --- Resolve SHAs (shared ls-remote helper) ---
if ! UP_SHA="$(git_resolve_remote_sha "$UPSTREAM_FULL" "$BRANCH")"; then
  log "FAIL could not resolve upstream refs/heads/$BRANCH"
  write_status "failed" ""; exit 0
fi
[[ -n "$UP_SHA" ]] || { log "upstream branch $BRANCH not found"; write_status "failed" ""; exit 0; }

if ! PR_SHA="$(git_resolve_remote_sha "$PRIVATE_FULL" "$BRANCH")"; then
  log "FAIL could not resolve private refs/heads/$BRANCH (not created yet?)"
  write_status "skipped" ""; exit 0
fi
[[ -n "$PR_SHA" ]] || { log "private branch $BRANCH not found (mirror not created yet)"; write_status "skipped" ""; exit 0; }

log "upstream=$UP_SHA private=$PR_SHA"

if [[ "$UP_SHA" == "$PR_SHA" ]]; then
  log "already in sync"
  write_status "ok" "$PR_SHA"; exit 0
fi

# --- Check divergence with a depth-bounded fetch (shared ancestry helper) ---
# If either clone failed, it reports "unknown" => conservative treatment (diverged).
ancestry="$(git_ancestry_check "$UPSTREAM_FULL" "$PRIVATE_FULL" "$UP_SHA" "$PR_SHA" "$TMPDIR_RUN")"

if [[ "$ancestry" == "private_ahead" ]]; then
  log "private is ahead of upstream — nothing to pull"
  write_status "ok" "$PR_SHA"; exit 0
fi

if [[ "$ancestry" == "upstream_ahead" ]]; then
  log "fast-forwarding private to upstream $UP_SHA"
  if git_push_private "$PRIVATE_FULL" "$BRANCH" ff-only; then
    log "fast-forward pushed"
    write_status "ok" "$UP_SHA"; exit 0
  fi
  # --force-with-lease guards against racing writers; on failure treat as diverged
  log "fast-forward push refused — treating as diverged"
fi

# --- Diverged: no force-push. Issue + optional auto-pause PR. ---
log "DIVERGED: private and upstream have diverged on $BRANCH"
write_status "diverged" "$PR_SHA"

if [[ "$OPEN_ISSUE" == "true" ]]; then
  body=$(jq -nc \
    --arg up "$UPSTREAM_FULL" \
    --arg pr "$PRIVATE_FULL" \
    --arg br "$BRANCH" \
    --arg upsha "$UP_SHA" \
    --arg prsha "$PR_SHA" \
    '{title:("Mirror diverged: " + $pr),
      body:("Private mirror `" + $pr + "` has diverged from upstream `" + $up + "` on branch `" + $br + "`.\n\n- upstream: `" + $upsha + "`\n- private:  `" + $prsha + "`\n\nFast-forward is impossible. The mirror has been auto-paused; reconcile manually (merge or rewrite) then unpause.") }')
  issue_json="$TMPDIR_RUN/issue.json"
  http="$(curl -sS -o "$issue_json" -w '%{http_code}' \
    -H "Accept: application/vnd.github+json" \
    -H "Authorization: Bearer ${GH_TOKEN}" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    -d "$body" \
    "https://api.github.com/repos/${GITHUB_REPOSITORY}/issues")"
  [[ "$http" == "201" ]] \
    && log "divergence issue created: $(jq -r '.html_url' "$issue_json")" \
    || log "issue creation failed (HTTP $http): $(jq -r '.message // .' "$issue_json" 2>/dev/null || true)"
fi

if [[ "$PAUSE_REPO" == "true" ]]; then
  # Auto-pause via PR (never write tracker/registry on main directly).
  regfile="$REG_DIR/$key.json"
  if [[ -f "$regfile" ]] && ! jq -e '.paused == true' "$regfile" >/dev/null 2>&1; then
    base_branch="${BASE_BRANCH:-main}"
    branch_name="pause/${PRIVATE_FULL//\//-}-$(date -u +%Y%m%d%H%M%S)"

    # Remember where we were so the pause PR branch NEVER leaks into the caller's
    # working tree (the sync-mirrors.yml main push must not ride on a pause/*).
    orig_ref="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo HEAD)"
    git checkout -b "$branch_name" "origin/$base_branch" 2>/dev/null \
      || git checkout -b "$branch_name" "$base_branch" 2>/dev/null \
      || git checkout -b "$branch_name"

    jq '.paused=true | .pause_reason="diverged from upstream (auto-paused by sync-mirror)"' "$regfile" | write_json_stable "$regfile"
    git add "$regfile"
    git -c user.email="bot@dpost.me" -c user.name="git-private-repo-manager" \
      commit -m "pause: $PRIVATE_FULL diverged from upstream" >/dev/null 2>&1 \
      || { log "nothing to commit for pause"; git checkout -q "$orig_ref" 2>/dev/null || true; exit 0; }
    git push "https://github.com/${GITHUB_REPOSITORY}.git" "$branch_name" >/dev/null 2>&1

    pr_body=$(jq -nc \
      --arg t "pause: $PRIVATE_FULL (diverged)" \
      --arg h "$branch_name" \
      --arg b "Auto-paused by \`sync-mirror.yml\`: \`$PRIVATE_FULL\` diverged from \`$UPSTREAM_FULL\` on branch \`$BRANCH\`. Reconcile manually, then set \`paused\` back to \`false\`." \
      '{title:$t, head:$h, base:"main", body:$b}')
    pause_json="$TMPDIR_RUN/pause.json"
    http="$(curl -sS -o "$pause_json" -w '%{http_code}' \
      -H "Accept: application/vnd.github+json" \
      -H "Authorization: Bearer ${GH_TOKEN}" \
      -H "X-GitHub-Api-Version: 2022-11-28" \
      -d "$pr_body" \
      "https://api.github.com/repos/${GITHUB_REPOSITORY}/pulls")"
    [[ "$http" == "201" ]] \
      && log "auto-pause PR opened: $(jq -r '.html_url' "$pause_json")" \
      || log "auto-pause PR creation failed (HTTP $http)"

    # CRITICAL: return to the original branch so the caller (sync-mirrors.yml
    # main push) cannot pick up the pause/* registry edit. commit-bot-changes.sh
    # re-checks out the default branch as a second guard.
    git checkout -q "$orig_ref" 2>/dev/null || true
  fi
fi

exit 0
