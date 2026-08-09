#!/usr/bin/env bash
# tests/test-lib-gh.sh
# Unit tests for .github/scripts/lib-gh.sh pure helpers
# (is_valid_owner_or_repo, is_valid_branch, is_full_repo).

set -uo pipefail
cd "$(git rev-parse --show-toplevel)" || { echo "must run inside git repo"; exit 2; }
# shellcheck source=/dev/null
source .github/scripts/lib-gh.sh

fail=0
check() { # desc expected actual
  if [[ "$3" == "$2" ]]; then echo "  PASS  $1"; else echo "  FAIL  $1 (expected '$2', got '$3')"; fail=1; fi
}

echo "== is_valid_owner_or_repo =="
check "simple org/repo" "yes" "$(is_valid_owner_or_repo cyfen-code/paperclip; echo yes)"
check "multi-level name ok" "yes" "$(is_valid_owner_or_repo ionix-ray/aws-eks-demo; echo yes)"
check "brackets rejected" "no" "$(is_valid_owner_or_repo 'ionix-ray/[abc]'; echo no)"
check "underscore start rejected" "no" "$(is_valid_owner_or_repo '_bad/repo'; echo no)"
check "slash-only rejected" "no" "$(is_valid_owner_or_repo 'a/b/c'; echo no)"
check "missing slash rejected" "no" "$(is_valid_owner_or_repo 'norepo'; echo no)"
check "empty rejected" "no" "$(is_valid_owner_or_repo ''; echo no)"

echo "== is_valid_branch =="
check "normal branch" "yes" "$(is_valid_branch main; echo yes)"
check "feature branch" "yes" "$(is_valid_branch feat/add-x; echo yes)"
check "spaces rejected" "no" "$(is_valid_branch 'bad branch'; echo no)"
check "empty rejected" "no" "$(is_valid_branch ''; echo no)"

echo "== is_full_repo =="
check "owner/repo" "yes" "$(is_full_repo a/b; echo yes)"
check "owner/repo/sub" "yes" "$(is_full_repo a/b/sub; echo yes)"
check "just one seg" "no" "$(is_full_repo a; echo no)"
check "empty" "no" "$(is_full_repo ''; echo no)"

echo ""
if (( fail )); then echo "=== lib-gh test: FAIL ==="; exit 1; fi
echo "=== lib-gh test: PASS ==="
exit 0
