#!/usr/bin/env bash
# cleanup-deleted.sh
# Scans .github/synced-repos.yml and removes entries where the upstream
# or private repo no longer exists (HTTP 404/451). Also marks archived upstreams.
# Safe: writes only after confirming changes; idempotent on clean registry.
#
# Env: GH_TOKEN, REG (optional, default .github/synced-repos.yml)

set -euo pipefail

: "${GH_TOKEN:?}" || { echo "::error::GH_TOKEN required"; exit 1; }
REG="${REG:-.github/synced-repos.yml}"

if [[ ! -f "$REG" ]]; then
  echo "registry missing — nothing to clean"
  exit 0
fi

TMPDIR_RUN="$(mktemp -d -t cleanup.XXXXXXXX)"
trap 'rm -rf "$TMPDIR_RUN"' EXIT
chmod 0700 "$TMPDIR_RUN"

U_JSON="$TMPDIR_RUN/up.json"
P_JSON="$TMPDIR_RUN/pr.json"
RATE_LIMIT_CHECK="$TMPDIR_RUN/ratelimit.json"

# --- Rate limit sanity check first ---
rl=$(curl -sS -o "$RATE_LIMIT_CHECK" -w '%{http_code}' \
  -H "Accept: application/vnd.github+json" \
  -H "Authorization: Bearer ${GH_TOKEN}" \
  -H "X-GitHub-Api-Version: 2022-11-28" \
  "https://api.github.com/rate_limit")
if [[ "$rl" == "200" ]]; then
  remaining=$(jq -r '.resources.core.remaining // 0' "$RATE_LIMIT_CHECK")
  if (( remaining < 50 )); then
    echo "::warning::rate limit low ($remaining remaining) — skipping cleanup"
    exit 0
  fi
fi

count=$(yq -r '.repos | length' "$REG")
[[ "$count" =~ ^[0-9]+$ ]] || { echo "::error::invalid repo count"; exit 1; }
(( count == 0 )) && { echo "registry empty — nothing to clean"; exit 0; }

deleted_indices=()
for i in $(seq 0 $((count - 1))); do
  up=$(IDX="$i" yq -r '.repos[env(IDX) | tonumber].upstream' "$REG")
  pr=$(IDX="$i" yq -r '.repos[env(IDX) | tonumber].private'  "$REG")

  if ! [[ "$up" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*/[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
    echo "::warning::malformed upstream '$up' at index $i — skipping"
    continue
  fi
  if ! [[ "$pr" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*/[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
    echo "::warning::malformed private '$pr' at index $i — skipping"
    continue
  fi

  uh=$(curl -sS -o "$U_JSON" -w '%{http_code}' \
    -H "Accept: application/vnd.github+json" \
    -H "Authorization: Bearer ${GH_TOKEN}" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    "https://api.github.com/repos/${up}" 2>/dev/null || echo "000")
  ph=$(curl -sS -o "$P_JSON" -w '%{http_code}' \
    -H "Accept: application/vnd.github+json" \
    -H "Authorization: Bearer ${GH_TOKEN}" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    "https://api.github.com/repos/${pr}" 2>/dev/null || echo "000")

  if [[ "$uh" == "403" || "$ph" == "403" ]]; then
    msg=$(jq -r '.message // ""' "$U_JSON" 2>/dev/null || true)
    if [[ "$msg" == *"rate limit"* ]]; then
      echo "::error::GitHub rate limit hit — aborting cleanup"
      exit 1
    fi
  fi

  remove=0
  reason=""
  if [[ "$uh" == "404" || "$uh" == "451" ]]; then
    remove=1
    reason="upstream deleted (HTTP $uh)"
  elif [[ "$ph" == "404" || "$ph" == "451" ]]; then
    remove=1
    reason="private deleted (HTTP $ph)"
  elif [[ "$uh" == "000" && "$ph" == "000" ]]; then
    echo "::warning::network failure checking $up / $pr — skipping"
    continue
  fi

  # Mark archived upstreams
  if [[ "$uh" == "200" ]]; then
    arch=$(jq -r '.archived // false' "$U_JSON")
    if [[ "$arch" == "true" ]]; then
      IDX="$i" ARCH="$arch" \
        yq -i '.repos[env(IDX) | tonumber].upstream_archived = (env(ARCH) == "true")' "$REG"
    fi
  fi

  if (( remove )); then
    echo "::notice::removing $up -> $pr ($reason)"
    deleted_indices+=("$i")
  fi
done

# Remove from highest index downward to preserve ordering
if (( ${#deleted_indices[@]} > 0 )); then
  mapfile -t sorted < <(printf '%s\n' "${deleted_indices[@]}" | sort -rn)
  for idx in "${sorted[@]}"; do
    IDX="$idx" yq -i 'del(.repos[env(IDX) | tonumber])' "$REG"
  done
  echo "cleaned ${#deleted_indices[@]} deleted repo(s)"
else
  echo "no deleted repos found"
fi
