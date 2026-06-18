#!/usr/bin/env bash
# validate-registry.sh
# Schema + semantic checks on .github/synced-repos.yml.
# Exits non-zero on CRITICAL. WARN/NOTABLE only logged.
# Skips upstream/private liveness checks unless --live is passed (those need GH_TOKEN).

set -euo pipefail

REG=".github/synced-repos.yml"
SCHEMA=".github/registry.schema.json"
LIVE="${1:-}"

if [[ ! -f "$REG" ]]; then
  echo "::error::registry $REG missing"
  exit 1
fi

# YAML parseable
yq '.' "$REG" >/dev/null

# JSON schema (uses python jsonschema if available, else skip with warning)
if command -v python3 >/dev/null 2>&1 && python3 -c 'import jsonschema' 2>/dev/null; then
  python3 - "$REG" "$SCHEMA" <<'PY'
import json, sys, yaml, jsonschema
reg = yaml.safe_load(open(sys.argv[1]))
schema = json.load(open(sys.argv[2]))
jsonschema.validate(reg, schema)
print("schema OK")
PY
else
  echo "::warning::python jsonschema not available — skipping JSON-schema validation"
fi

# Duplicate detection
dup_up=$(yq -r '.repos | group_by(.upstream) | map(select(length > 1)) | length' "$REG")
dup_pr=$(yq -r '.repos | group_by(.private)  | map(select(length > 1)) | length' "$REG")
if [[ "$dup_up" != "0" ]]; then echo "::error::duplicate upstream entries in registry"; exit 1; fi
if [[ "$dup_pr" != "0" ]]; then echo "::error::duplicate private entries in registry";  exit 1; fi

count=$(yq -r '.repos | length' "$REG")
echo "registry valid: $count repo(s)"

if [[ "$LIVE" != "--live" ]]; then exit 0; fi
: "${GH_TOKEN:?live mode requires GH_TOKEN}"

# Owner/repo charset sanity check.
is_full_repo() { [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*/[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; }

TMPDIR_RUN="$(0)"
chmod 0700 "$TMPDIR_RUN"
trap 'rm -rf "$TMPDIR_RUN"' EXIT
U_JSON="$TMPDIR_RUN/u.json"
P_JSON="$TMPDIR_RUN/p.json"

critical=0
warn=0
notable=0
for i in $(seq 0 $((count - 1))); do
  up=$(IDX="$i" yq -r '.repos[env(IDX) | tonumber].upstream' "$REG")
  pr=$(IDX="$i" yq -r '.repos[env(IDX) | tonumber].private'  "$REG")

  if ! is_full_repo "$up" || ! is_full_repo "$pr"; then
    echo "::error::CRITICAL: registry entry $i has malformed upstream/private"
    critical=$((critical+1))
    continue
  fi

  # upstream reachable
  uh=$(curl -sS -o "$U_JSON" -w '%{http_code}' \
    -H "Accept: application/vnd.github+json" \
    -H "Authorization: Bearer ${GH_TOKEN}" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    "https://api.github.com/repos/${up}")
  if [[ "$uh" != "200" ]]; then
    echo "::error::CRITICAL: upstream $up unreachable (HTTP $uh)"
    critical=$((critical+1))
    continue
  fi

  # private exists + visibility=private
  ph=$(curl -sS -o "$P_JSON" -w '%{http_code}' \
    -H "Accept: application/vnd.github+json" \
    -H "Authorization: Bearer ${GH_TOKEN}" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    "https://api.github.com/repos/${pr}")
  if [[ "$ph" != "200" ]]; then
    echo "::error::CRITICAL: private $pr unreachable (HTTP $ph)"
    critical=$((critical+1))
    continue
  fi
  vis=$(jq -r '.visibility // (.private | if . then "private" else "public" end)' "$P_JSON")
  if [[ "$vis" != "private" ]]; then
    echo "::error::CRITICAL: $pr visibility=$vis — must be private"
    critical=$((critical+1))
  fi

  # archived upstream
  arch=$(jq -r '.archived' "$U_JSON")
  if [[ "$arch" == "true" ]]; then
    echo "::warning::WARN: upstream $up is archived — consider pausing"
    warn=$((warn+1))
  fi

  # default branch drift
  udb=$(jq -r '.default_branch' "$U_JSON")
  tdb=$(IDX="$i" yq -r '.repos[env(IDX) | tonumber].upstream_default_branch // ""' "$REG")
  if [[ -n "$tdb" && "$udb" != "$tdb" ]]; then
    echo "::warning::WARN: $up default_branch changed $tdb -> $udb"
    warn=$((warn+1))
  fi
done

echo "validation: critical=$critical warn=$warn notable=$notable"
[[ "$critical" == "0" ]] || exit 1
