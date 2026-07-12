#!/usr/bin/env bash
# tests/run-schema-tests.sh
# Validates per-record fixtures against the tracker schemas.
# Naming convention encodes the expected outcome:
#   valid-*  -> must PASS (exit 0)
#   bad-*    -> must FAIL (exit 1)
# Registry fixtures  -> tracker/schemas/registry-record.schema.json
# Metadata fixtures  -> tracker/schemas/metadata-record.schema.json

set -uo pipefail
cd "$(git rev-parse --show-toplevel)" || { echo "must run inside git repo"; exit 2; }

SCHEMA_DIR="tracker/schemas"
pass=0; fail=0; failed_names=()

check_one() {  # schema fixture expected
  local schema="$1" fx="$2" expected="$3"
  python3 - "$schema" "$fx" <<'PY'
import json, sys, jsonschema
schema = json.load(open(sys.argv[1]))
try:
    jsonschema.validate(json.load(open(sys.argv[2])), schema)
    sys.exit(0)
except jsonschema.ValidationError:
    sys.exit(1)
except json.JSONDecodeError:
    sys.exit(1)
PY
  local actual=$?
  local name; name="$(basename "$fx")"
  if [[ "$actual" == "$expected" ]]; then
    printf "  PASS  %-40s expected=%d got=%d\n" "$name" "$expected" "$actual"; pass=$((pass+1))
  else
    printf "  FAIL  %-40s expected=%d got=%d\n" "$name" "$expected" "$actual"; fail=$((fail+1)); failed_names+=("$name")
  fi
}

run_dir() {  # schema dir
  local schema="$1" dir="$2"
  shopt -s nullglob
  for fx in "$dir"/*.json; do
    case "$(basename "$fx")" in
      valid-*) exp=0 ;;
      bad-*)   exp=1 ;;
      *) echo "  SKIP  $(basename "$fx")"; continue ;;
    esac
    check_one "$schema" "$fx" "$exp"
  done
  shopt -u nullglob
}

echo "== registry-record fixtures =="
run_dir "$SCHEMA_DIR/registry-record.schema.json" tests/fixtures/registry
echo "== metadata-record fixtures =="
run_dir "$SCHEMA_DIR/metadata-record.schema.json" tests/fixtures/metadata

echo ""
echo "=== schema-tests summary ==="
echo "pass: $pass    fail: $fail    total: $((pass + fail))"
if (( fail > 0 )); then echo "failed: ${failed_names[*]}"; exit 1; fi
exit 0
