#!/usr/bin/env bash
# Every third-party GitHub Action must be pinned to a full commit SHA.
#
# Tags are mutable: the upstream owner can repoint v4 at any time, so a tag
# reference does not describe the code CI will execute. deploy-site.yml holds
# pages:write and id-token:write, and repo-tests.yml runs on pull_request —
# both are places where silently-changed third-party code matters (#36).
#
# Local composite actions (./actions/...) are in-tree and need no pin.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

errors=0; pass=0
ok()   { echo "PASS: $1"; pass=$((pass+1)); }
fail() { echo "FAIL: $1"; errors=$((errors+1)); }

mapfile -t refs < <(
  grep -rhoE '^[[:space:]]*-?[[:space:]]*uses:[[:space:]]*[^[:space:]]+' \
    "$SCRIPT_DIR/.github/workflows" "$SCRIPT_DIR/actions" 2>/dev/null |
    sed -E 's/.*uses:[[:space:]]*//' | sort -u
)

[[ ${#refs[@]} -gt 0 ]] && ok "found ${#refs[@]} action reference(s)" \
                        || fail "no action references found — check the scan paths"

for ref in "${refs[@]}"; do
  case "$ref" in
    ./*) ok "local action not pinned: $ref" ; continue ;;
  esac
  version="${ref##*@}"
  if [[ "$version" =~ ^[0-9a-f]{40}$ ]]; then
    ok "pinned to a SHA: $ref"
  else
    fail "mutable ref (pin to a 40-char commit SHA): $ref"
  fi
done

# A pin is only maintainable if something bumps it.
dependabot="$SCRIPT_DIR/.github/dependabot.yml"
if [[ -f "$dependabot" ]] && grep -q 'github-actions' "$dependabot"; then
  ok "dependabot tracks the github-actions ecosystem"
else
  fail "no dependabot config for github-actions — pins will rot"
fi

echo "---"; echo "Passed: $pass"; echo "Failed: $errors"
exit $((errors > 0 ? 1 : 0))
