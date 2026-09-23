#!/usr/bin/env bash
# validate-owner.sh OWNER
# Verifies the secret-store PAT (env GH_TOKEN) can work under OWNER (user/org).
# Pure `gh` CLI + `git` — no raw REST, no curl. Never echoes the token.
# Exits non-zero on any failure.
#
# Checks: token present, `gh auth status` green, login parsed from that same
# output (no extra calls), OWNER resolvable via `gh repo list`, classic-token
# scope check when the scopes line is present, else required-permissions
# guidance. Write access itself is enforced server-side at create/push time
# with diagnostics there.

set -euo pipefail

OWNER="${1:?owner required}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$SCRIPT_DIR/lib-gh.sh"

is_valid_owner_or_repo "$OWNER" || {
  echo "::error::owner '$OWNER' has unsupported characters"
  exit 1
}

require_gh_token || exit 1
mask_token || exit 1

AUTH_OUT="$(gh auth status 2>&1)" || {
  echo "::error::PAT auth failed (gh auth status non-zero)"
  exit 1
}
me="$(sed -n 's/.*account \([^ ]*\).*/\1/p' <<<"$AUTH_OUT" | head -n 1)"
[[ -n "$me" ]] || { echo "::error::could not parse login from gh auth status"; exit 1; }
echo "PAT identity: '$me'"

# Owner must resolve and be listable (works for users and orgs alike).
if ! gh repo list "$OWNER" --limit 1 --json nameWithOwner >/dev/null 2>&1; then
  echo "::error::owner '$OWNER' not found or not readable with this PAT"
  exit 1
fi

if [[ "$me" == "$OWNER" ]]; then
  kind="User"
  echo "owner '$OWNER' is the PAT user"
else
  kind="Organization (assumed — membership + write enforced server-side at create/push)"
  echo "owner '$OWNER' differs from PAT user '$me' — treating as organization"
fi

# Detect token style — fine-grained PATs / App tokens don't expose classic scopes.
token_kind_="$(token_kind)"
echo "PAT kind: $token_kind_"

scopes_line="$(grep -i "token scopes" <<<"$AUTH_OUT" || true)"
if [[ -n "$scopes_line" ]]; then
  echo "PAT scopes: $scopes_line"
  missing=()
  for need in "'repo'" "'workflow'"; do
    grep -q "$need" <<<"$scopes_line" || missing+=("$need")
  done
  # 'repo' alone suffices for classic repo work; workflow only matters for
  # pushing workflow files — flag it but do not fail (server enforces).
  if grep -q "'repo'" <<<"$scopes_line"; then
    echo "scope check passed (repo present)"
  else
    echo "::error::classic PAT missing required scope 'repo'"
    exit 1
  fi
  if [[ ${#missing[@]} -gt 0 ]]; then
    echo "::warning::classic PAT may lack: ${missing[*]} (needed only if workflows/ files are pushed)"
  fi
else
  echo "::notice::no classic scope line (kind '$token_kind_') — skipping scope check; required PAT permissions:"
  echo "  classic: 'repo' (+ 'workflow' if pushing workflow files)"
  echo "  fine-grained: Administration read/write + Contents read/write (+ Actions/Workflows read/write as needed)"
fi

echo "owner=$OWNER kind=$kind validated"
