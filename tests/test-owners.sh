#!/usr/bin/env bash
# tests/test-owners.sh
# Verifies the config-driven owner model:
#   1. tracker/owners.json validates against tracker/schemas/owners.schema.json
#   2. resolve-owner.sh resolves every configured owner (and rejects unknown)
#   3. Every `target_owner` dropdown option in .github/workflows/*.yml is
#      declared in tracker/owners.json (no drift -> a dropdown choice that
#      could never land because the secret/env is undefined).

set -uo pipefail
cd "$(git rev-parse --show-toplevel)" || { echo "must run inside git repo"; exit 2; }

fail=0
note() { printf '  %s\n' "$*"; }
check() { # desc expected actual
  if [[ "$3" == "$2" ]]; then note "PASS  $1"; else note "FAIL  $1 (expected '$2', got '$3')"; fail=1; fi
}

echo "== 1. owners.json validates against schema =="
python3 - tracker/schemas/owners.schema.json tracker/owners.json <<'PY'
import json, sys, jsonschema
jsonschema.validate(json.load(open(sys.argv[2])), json.load(open(sys.argv[1])))
print("schema OK")
PY
check "owners.json schema valid" "$?" "0"

echo "== 2. resolve-owner resolves every configured owner =="
configured=$(jq -r '.owners[].owner' tracker/owners.json)
for o in $configured; do
  out="$(bash .github/scripts/resolve-owner.sh "$o")" || { note "FAIL resolve $o"; fail=1; continue; }
  if [[ "$out" == *"resolved owner='$o' secret="* ]]; then
    note "PASS  resolve $o"
  else
    note "FAIL  resolve $o -> $out"; fail=1
  fi
done

echo "== 3. unknown owner is rejected =="
out="$(bash .github/scripts/resolve-owner.sh __no_such_owner__ 2>&1)"
case "$out" in
  *invalid\ owner*|*not\ configured*) note "PASS  unknown owner rejected" ;;
  *) note "FAIL  unknown owner accepted: $out"; fail=1 ;;
esac

echo "== 4. workflow target_owner dropdowns match owners.json =="
# Parse every `options:` under a `target_owner` choice input across workflows.
# Uses python (yaml may not be installed everywhere) — fallback to awk/jq.
dropdowns="$(python3 - .github/workflows <<'PY'
import glob, sys, os, re
seen = {}
for f in glob.glob(os.path.join(sys.argv[1], "*.yml")) + glob.glob(os.path.join(sys.argv[1], "*.yaml")):
    txt = open(f).read()
    if "target_owner" not in txt:
        continue
    m = re.search(r'target_owner:\s*\n(.*?)(?=\n      [a-z_]+:|\Z)', txt, re.S)
    if not m:
        m = re.search(r'description:.*?target_owner.*?\n', txt, re.S)
    opts = re.findall(r'-\s+([a-zA-Z0-9._-]+)', m.group(1) if m else "")
    if opts:
        seen[os.path.basename(f)] = sorted(opts)
for f, opts in sorted(seen.items()):
    print(f, " ".join(opts))
PY
)"
[[ -n "$dropdowns" ]] || { note "FAIL  could not parse target_owner dropdowns"; fail=1; }

while IFS= read -r line; do
  [[ -z "$line" ]] && continue
  wf=${line%% *}
  opts=${line#* }
  for opt in $opts; do
    if jq -e --arg o "$opt" '.owners[] | select(.owner == $o)' tracker/owners.json >/dev/null; then
      note "PASS  $wf option '$opt' is configured"
    else
      note "FAIL  $wf option '$opt' is NOT in tracker/owners.json — mirror would fail to land"
      fail=1
    fi
  done
done <<< "$dropdowns"

echo ""
if (( fail )); then echo "=== owners test: FAIL ==="; exit 1; fi
echo "=== owners test: PASS ==="
exit 0
