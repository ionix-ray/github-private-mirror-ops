#!/usr/bin/env bash
# validate-registry.sh [--live]
# Offline: validates tracker/config.json + every tracker/registry/*.json and
# tracker/metadata/*.json against tracker/schemas/*, checks cross-record invariants
# (unique upstream, unique private, key matches private, metadata orphans).
# --live: additionally verifies upstream/private reachability (needs GH_TOKEN).
#
# Honors TRACKER_DIR so tests can point it at a fixture tree.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$SCRIPT_DIR/lib-tracker.sh"

LIVE="${1:-}"

[[ -d "$REG_DIR" ]]    || { echo "::error::registry dir $REG_DIR missing"; exit 1; }
[[ -d "$SCHEMA_DIR" ]] || { echo "::error::schema dir $SCHEMA_DIR missing"; exit 1; }

python3 - "$CONFIG_FILE" "$REG_DIR" "$META_DIR" "$SCHEMA_DIR" << 'PY'
import json, sys, os, glob, re
try:
    import jsonschema
except Exception as e:
    print(f"::error::jsonschema not installed: {e}"); sys.exit(2)

config_file, reg_dir, meta_dir, schema_dir = sys.argv[1:5]
errors = []

def load(p):
    with open(p) as f: return json.load(f)

cfg_schema  = load(os.path.join(schema_dir, "config.schema.json"))
reg_schema  = load(os.path.join(schema_dir, "registry-record.schema.json"))
meta_schema = load(os.path.join(schema_dir, "metadata-record.schema.json"))

def key(full): return full.replace("/", "__")

# --- config.json ---
if not os.path.exists(config_file):
    errors.append(f"{config_file}: missing")
else:
    try:
        jsonschema.validate(load(config_file), cfg_schema)
    except jsonschema.ValidationError as e:
        errors.append(f"{config_file}: {e.message}")

# --- intent records ---
upstreams, privates = {}, {}
reg_files = sorted(glob.glob(os.path.join(reg_dir, "*.json")))
for rf in reg_files:
    base = os.path.basename(rf)
    try:
        rec = load(rf)
    except json.JSONDecodeError as e:
        errors.append(f"{base}: invalid JSON ({e})"); continue
    try:
        jsonschema.validate(rec, reg_schema)
    except jsonschema.ValidationError as e:
        errors.append(f"{base}: {e.message}"); continue
    up, pr = rec["upstream"], rec["private"]
    expected = key(pr) + ".json"
    if base != expected:
        errors.append(f"{base}: filename must match private key ({expected})")
    if up in upstreams:
        errors.append(f"duplicate upstream {up} in {base} and {upstreams[up]}")
    upstreams[up] = base
    if pr in privates:
        errors.append(f"duplicate private {pr} in {base} and {privates[pr]}")
    privates[pr] = base

# --- metadata records ---
meta_files = sorted(glob.glob(os.path.join(meta_dir, "*.json"))) if os.path.isdir(meta_dir) else []
reg_keys = set()
for rf in reg_files:
    try: reg_keys.add(key(load(rf)["private"]))
    except Exception: pass

for mf in meta_files:
    base = os.path.basename(mf)
    try:
        rec = load(mf)
    except json.JSONDecodeError as e:
        errors.append(f"{base}: invalid JSON ({e})"); continue
    try:
        jsonschema.validate(rec, meta_schema)
    except jsonschema.ValidationError as e:
        errors.append(f"metadata/{base}: {e.message}"); continue
    k = base[:-5]
    if k not in reg_keys:
        errors.append(f"metadata/{base}: orphan (no matching intent record)")

if errors:
    print(f"::error::validation failed ({len(errors)} error(s))")
    for e in errors: print(f"  - {e}")
    sys.exit(1)
print(f"registry valid: {len(reg_files)} intent record(s), {len(meta_files)} metadata record(s)")
PY
offline_rc=$?
[[ $offline_rc -eq 0 ]] || exit $offline_rc

if [[ "$LIVE" != "--live" ]]; then exit 0; fi
: "${GH_TOKEN:?live mode requires GH_TOKEN}"

TMPDIR_RUN="$(mktemp -d -t validate.XXXXXXXX)"
trap 'rm -rf "$TMPDIR_RUN"' EXIT
U_JSON="$TMPDIR_RUN/u.json"; P_JSON="$TMPDIR_RUN/p.json"
critical=0; warn=0
while IFS= read -r rf; do
  [[ -z "$rf" ]] && continue
  up=$(jq -r '.upstream' "$rf"); pr=$(jq -r '.private' "$rf")
  is_full_repo "$up" && is_full_repo "$pr" || { echo "::error::CRITICAL: malformed $(basename "$rf")"; critical=$((critical+1)); continue; }
  uh=$(curl -sS -o "$U_JSON" -w '%{http_code}' -H "Accept: application/vnd.github+json" \
    -H "Authorization: Bearer ${GH_TOKEN}" -H "X-GitHub-Api-Version: 2022-11-28" \
    "https://api.github.com/repos/${up}")
  [[ "$uh" == "200" ]] || { echo "::error::CRITICAL: upstream $up unreachable (HTTP $uh)"; critical=$((critical+1)); continue; }
  ph=$(curl -sS -o "$P_JSON" -w '%{http_code}' -H "Accept: application/vnd.github+json" \
    -H "Authorization: Bearer ${GH_TOKEN}" -H "X-GitHub-Api-Version: 2022-11-28" \
    "https://api.github.com/repos/${pr}")
  [[ "$ph" == "200" ]] || { echo "::error::CRITICAL: private $pr unreachable (HTTP $ph)"; critical=$((critical+1)); continue; }
  vis=$(jq -r '.visibility // (.private | if . then "private" else "public" end)' "$P_JSON")
  [[ "$vis" == "private" ]] || { echo "::error::CRITICAL: $pr visibility=$vis — must be private"; critical=$((critical+1)); }
  [[ "$(jq -r '.archived' "$U_JSON")" == "true" ]] && { echo "::warning::WARN: upstream $up archived"; warn=$((warn+1)); }
done < <(list_registry_files)
echo "validation: critical=$critical warn=$warn"
[[ "$critical" == "0" ]] || exit 1
