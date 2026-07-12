#!/usr/bin/env bash
# lib-tracker.sh — shared paths + helpers for the tracker registry.
# Source this from other scripts:  . "$(dirname "$0")/lib-tracker.sh"
#
# Design invariant (this is what makes registration conflict-free):
#   * INTENT   lives in tracker/registry/<key>.json  — human/PR-owned, one file per mirror.
#   * METADATA lives in tracker/metadata/<key>.json  — bot-owned, one file per mirror.
#   * The register (PR) path writes ONLY registry/*.  The sync (bot) path writes ONLY
#     metadata/* + the generated read-model.  The two sets are disjoint, so a daily
#     metadata commit and an open registration PR can never touch the same bytes.
#   * Adding a mirror = adding a NEW file, so even simultaneous registrations never collide.

set -euo pipefail

TRACKER_DIR="${TRACKER_DIR:-tracker}"
REG_DIR="${REG_DIR:-$TRACKER_DIR/registry}"
META_DIR="${META_DIR:-$TRACKER_DIR/metadata}"
SCHEMA_DIR="${SCHEMA_DIR:-$TRACKER_DIR/schemas}"
CONFIG_FILE="${CONFIG_FILE:-$TRACKER_DIR/config.json}"
JSON_OUT="${JSON_OUT:-repo-status.json}"
MD_OUT="${MD_OUT:-REPO_STATUS.md}"

# tracker_key OWNER/REPO -> owner__repo  (stable, filesystem-safe, collision-free
# because private full names are globally unique).
tracker_key() { printf '%s' "$1" | sed 's#/#__#g'; }

# Guard: owner/repo charset.
is_full_repo() { [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*/[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; }

# Emit newline-separated list of registry record paths (empty if none).
list_registry_files() {
  find "$REG_DIR" -maxdepth 1 -type f -name '*.json' 2>/dev/null | sort
}

# Deterministic JSON writer: sorted keys, 2-space indent, trailing newline.
# Minimal, stable diffs — only changed values change lines (no re-serialization churn).
write_json_stable() {
  local dest="$1"
  local tmp
  tmp="$(mktemp)"
  jq -S --indent 2 '.' > "$tmp"
  mv "$tmp" "$dest"
}
