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

critical=0
warn=0
notable=0
for i in $(seq 0 $((count - 1))); do
  up=$(yq -r ".repos[$i].upstream" "$REG")
  pr=$(yq -r ".repos[$i].private"  "$REG")
  br=$(yq -r ".repos[$i].branch"   "$REG")

  # upstream reachable
  uh=$(curl -sS -o /tmp/u.json -w '%{http_code}' \
    -H "Authorization: Bearer ${GH_TOKEN}" \
    "https://api.github.com/repos/${up}")
  if [[ "$uh" != "200" ]]; then
    echo "::error::CRITICAL: upstream $up unreachable (HTTP $uh)"
    critical=$((critical+1))
    continue
  fi

  # private exists + visibility=private
  ph=$(curl -sS -o /tmp/p.json -w '%{http_code}' \
    -H "Authorization: Bearer ${GH_TOKEN}" \
    "https://api.github.com/repos/${pr}")
  if [[ "$ph" != "200" ]]; then
    echo "::error::CRITICAL: private $pr unreachable (HTTP $ph)"
    critical=$((critical+1))
    continue
  fi
  vis=$(jq -r '.visibility // (.private | if . then "private" else "public" end)' /tmp/p.json)
  if [[ "$vis" != "private" ]]; then
    echo "::error::CRITICAL: $pr visibility=$vis — must be private"
    critical=$((critical+1))
  fi

  # archived upstream
  arch=$(jq -r '.archived' /tmp/u.json)
  if [[ "$arch" == "true" ]]; then
    echo "::warning::WARN: upstream $up is archived — consider pausing"
    warn=$((warn+1))
  fi

  # default branch drift
  udb=$(jq -r '.default_branch' /tmp/u.json)
  tdb=$(yq -r ".repos[$i].upstream_default_branch // \"\"" "$REG")
  if [[ -n "$tdb" && "$udb" != "$tdb" ]]; then
    echo "::warning::WARN: $up default_branch changed $tdb -> $udb"
    warn=$((warn+1))
  fi
done

echo "validation: critical=$critical warn=$warn notable=$notable"
[[ "$critical" == "0" ]] || exit 1
