#!/usr/bin/env bash
set -euo pipefail
MRA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIX="$MRA_DIR/tests/fixtures/sample-workspace"
errors=0
pass(){ echo "PASS: $1"; }
fail(){ echo "FAIL: $1"; errors=$((errors+1)); }

out=$(python3 "$MRA_DIR/scanners/walk.py" "$FIX")

# every line valid JSON
while IFS= read -r l; do [[ -z "$l" ]] && continue; echo "$l" | jq -e . >/dev/null || fail "invalid JSON: $l"; done <<<"$out"

has(){ echo "$out" | jq -e --arg s "$1" --arg t "$2" --arg sc "$3" 'select(.source==$s and .target==$t and .scanner==$sc)' >/dev/null && pass "$3: $1->$2" || fail "$3: missing $1->$2"; }
# docker-compose
has erp mysql docker-compose; has erp redis docker-compose; has billing mysql docker-compose
# shared-db
has erp mysql shared-db; has billing mysql shared-db
# api-calls (low)
has erp api-gateway api-calls; has erp billing api-calls; has erp catalog api-calls
has partner-api-gateway erp api-calls
# gateway-routes (medium)
has partner-api-gateway erp gateway-routes
# shared-packages (high)
has analytics erp shared-packages; has analytics billing shared-packages
has analytics @acme/erp shared-packages

# Full record-set equivalence against the committed golden set (generated
# from the now-deleted legacy scanners/*.sh on this fixture; see
# scanners/README.md for how the golden file is produced).
GOLD="$MRA_DIR/tests/fixtures/expected-records.jsonl"
if diff <(python3 "$MRA_DIR/scanners/walk.py" "$FIX" | jq -cS . | sort -u) <(jq -cS . < "$GOLD" | sort -u) >/dev/null; then
  pass "walk.py matches golden record set exactly"
else
  fail "walk.py differs from golden"
fi

[[ "$errors" -eq 0 ]] && echo "walk.py infra tests passed" || { echo "$errors failures"; exit 1; }
