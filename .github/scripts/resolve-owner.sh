#!/usr/bin/env bash
# resolve-owner.sh OWNER
# Config-driven owner -> secret/environment resolution for the workflows.
# Reads tracker/owners.json (via lib-gh.sh) and writes to $GITHUB_OUTPUT:
#     secret_name  — the Actions secret holding the owner's PAT
#     environment  — the Actions environment that scopes that secret
#
# Replaces the old hardcoded `case "$OWNER" in ...` blocks that were copied
# into every workflow. Adding a mirror target = one line in owners.json.

set -euo pipefail

OWNER="${1:?owner required}"
TRACKER_DIR="${TRACKER_DIR:-tracker}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$SCRIPT_DIR/lib-gh.sh"

result="$(resolve_owner_config "$OWNER" "$TRACKER_DIR")" || {
  echo "::error::$result"
  exit 1
}
read -r secret environment <<< "$result"
if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  echo "secret_name=$secret" >> "$GITHUB_OUTPUT"
  echo "environment=$environment" >> "$GITHUB_OUTPUT"
fi
echo "resolved owner='$OWNER' secret='$secret' environment='$environment'"
