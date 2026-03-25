#!/usr/bin/env bash
set -uo pipefail

MRA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKSPACE="${1:-/Users/hanfourhuang/OneAD}"

errors=0
pass=0

pass_test() {
  echo "PASS: $1"
  ((pass++)) || true
}

fail_test() {
  echo "FAIL: $1"
  ((errors++)) || true
}

assert_jsonl() {
  local scanner="$1" output="$2"
  local invalid=0
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    if ! echo "$line" | jq '.' &>/dev/null; then
      echo "  invalid JSON line: $line"
      ((invalid++)) || true
    fi
  done <<< "$output"
  if [[ $invalid -eq 0 ]]; then
    pass_test "$scanner: all output lines are valid JSON"
  else
    fail_test "$scanner: $invalid invalid JSON line(s)"
  fi
}

assert_has_output() {
  local scanner="$1" output="$2"
  local count
  count=$(echo "$output" | grep -c '^{' || true)
  if [[ "$count" -gt 0 ]]; then
    pass_test "$scanner: produced $count relationship(s)"
  else
    fail_test "$scanner: produced no output (expected at least 1 relationship)"
  fi
}

assert_contains_source_target() {
  local scanner="$1" output="$2" source="$3" target="$4"
  if echo "$output" | jq -e --arg s "$source" --arg t "$target" \
    'select(.source == $s and .target == $t)' &>/dev/null; then
    pass_test "$scanner: found $source -> $target"
  else
    fail_test "$scanner: missing $source -> $target"
  fi
}

echo "=== Scanner Tests against $WORKSPACE ==="
echo ""

# ---- docker-compose scanner ----
echo "--- docker-compose scanner ---"
dc_output=$(bash "$MRA_DIR/scanners/docker-compose.sh" "$WORKSPACE" 2>/dev/null)
assert_jsonl "docker-compose" "$dc_output"
assert_has_output "docker-compose" "$dc_output"

# Should find erp -> mysql, erp -> redis
assert_contains_source_target "docker-compose" "$dc_output" "erp" "mysql"
assert_contains_source_target "docker-compose" "$dc_output" "erp" "redis"

# Should find masa -> mysql (or masa -> redis)
if echo "$dc_output" | jq -e 'select(.source == "masa")' &>/dev/null; then
  pass_test "docker-compose: found masa dependencies"
else
  fail_test "docker-compose: missing masa dependencies"
fi

# Should find odm-ui service (even if no depends_on)
echo "  docker-compose found services: $(echo "$dc_output" | jq -r '.source' | sort -u | tr '\n' ' ')"
echo ""

# ---- shared-db scanner ----
echo "--- shared-db scanner ---"
db_output=$(bash "$MRA_DIR/scanners/shared-db.sh" "$WORKSPACE" 2>/dev/null)
assert_jsonl "shared-db" "$db_output"
assert_has_output "shared-db" "$db_output"

# erp and masa both use gspadmin -> both should emit mysql dependency
erp_mysql=$(echo "$db_output" | jq -e 'select(.source == "erp" and .target == "mysql")' 2>/dev/null || echo "")
masa_mysql=$(echo "$db_output" | jq -e 'select(.source == "masa" and .target == "mysql")' 2>/dev/null || echo "")

if [[ -n "$erp_mysql" && -n "$masa_mysql" ]]; then
  pass_test "shared-db: erp and masa both reference gspadmin (shared DB)"
else
  fail_test "shared-db: expected erp and masa to share gspadmin database"
fi
echo "  shared-db found: $(echo "$db_output" | jq -r '.source' | sort -u | tr '\n' ' ')"
echo ""

# ---- gateway-routes scanner ----
echo "--- gateway-routes scanner ---"
gw_output=$(bash "$MRA_DIR/scanners/gateway-routes.sh" "$WORKSPACE" 2>/dev/null)
assert_jsonl "gateway-routes" "$gw_output"
# Gateway scanner may produce 0 results if no gateways found - just validate JSONL
if [[ -z "$gw_output" ]]; then
  pass_test "gateway-routes: produced no output (no gateway routes configured)"
else
  assert_has_output "gateway-routes" "$gw_output"
  echo "  gateway-routes found: $(echo "$gw_output" | jq -r '{source,target} | "\(.source) -> \(.target)"' | sort -u | tr '\n' '; ')"
fi

# partner-api-gateway should reference erp (has ERP_BASE_URL in env.example)
if echo "$gw_output" | jq -e 'select(.source == "partner-api-gateway" and .target == "erp")' &>/dev/null; then
  pass_test "gateway-routes: partner-api-gateway -> erp found"
else
  fail_test "gateway-routes: missing partner-api-gateway -> erp"
fi
echo ""

# ---- api-calls scanner ----
echo "--- api-calls scanner ---"
api_output=$(bash "$MRA_DIR/scanners/api-calls.sh" "$WORKSPACE" 2>/dev/null)
assert_jsonl "api-calls" "$api_output"
# api-calls may produce low-confidence output
if [[ -z "$api_output" ]]; then
  pass_test "api-calls: produced no output"
else
  assert_has_output "api-calls" "$api_output"
  # erp env.example has MOAI_HOST, MASA_HOST, API_GATEWAY_HOST
  if echo "$api_output" | jq -e 'select(.source == "erp")' &>/dev/null; then
    pass_test "api-calls: found erp dependencies"
  else
    fail_test "api-calls: missing erp dependencies (expected MOAI_HOST/MASA_HOST)"
  fi
fi
echo "  api-calls all confidence: $(echo "$api_output" | jq -r '.confidence' | sort | uniq -c)"
echo ""

# ---- shared-packages scanner ----
echo "--- shared-packages scanner ---"
pkg_output=$(bash "$MRA_DIR/scanners/shared-packages.sh" "$WORKSPACE" 2>/dev/null)
assert_jsonl "shared-packages" "$pkg_output"
if [[ -z "$pkg_output" ]]; then
  pass_test "shared-packages: produced no output (no internal packages found)"
else
  assert_has_output "shared-packages" "$pkg_output"
  echo "  shared-packages found: $(echo "$pkg_output" | jq -r '{source,target} | "\(.source) -> \(.target)"' | sort -u | head -5 | tr '\n' '; ')"
fi
echo ""

# ---- Required fields validation ----
echo "--- Required fields validation ---"
all_output=$(printf '%s\n%s\n%s\n%s\n%s\n' "$dc_output" "$db_output" "$gw_output" "$api_output" "$pkg_output")
missing_fields=0
while IFS= read -r line; do
  [[ -z "$line" ]] && continue
  for field in source target type confidence scanner; do
    if ! echo "$line" | jq -e ".$field" &>/dev/null; then
      echo "  missing field '$field' in: $line"
      ((missing_fields++)) || true
    fi
  done
done <<< "$all_output"
if [[ $missing_fields -eq 0 ]]; then
  pass_test "all fields: source, target, type, confidence, scanner present in all records"
else
  fail_test "missing fields in $missing_fields record(s)"
fi
echo ""

# ---- Summary ----
echo "=== Results: $pass passed, $errors failed ==="
if [[ $errors -eq 0 ]]; then
  exit 0
else
  exit 1
fi
