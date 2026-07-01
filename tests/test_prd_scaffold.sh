#!/usr/bin/env bash
# mra prd-scaffold apply: validate / PII / org / gate / create / register.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SCRIPT_DIR/lib/colors.sh"
source "$SCRIPT_DIR/lib/validate.sh"
source "$SCRIPT_DIR/lib/branch-ops.sh"
source "$SCRIPT_DIR/lib/config.sh"
source "$SCRIPT_DIR/lib/prd-issues.sh"   # _prd_account_token
source "$SCRIPT_DIR/lib/prd-scaffold.sh"

errors=0
ok()   { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; errors=$((errors+1)); }
assert_eq() { if [[ "$2" == "$3" ]]; then ok "$1"; else fail "$1 — expected [$2] got [$3]"; fi; }

WS=$(mktemp -d); mkdir -p "$WS/.collab/requirements"
printf '{"gitOrg":"git@github.com:acme","projects":{}}' > "$WS/.collab/dep-graph.json"
mk() { cat > "$WS/.collab/requirements/$1"; }

assert_eq "resolve bare org (ssh)" "acme" "$(_scaffold_resolve_org 'git@github.com:acme')"
assert_eq "resolve bare org (https)" "acme" "$(_scaffold_resolve_org 'https://github.com/acme')"

mk REQ-2026-0001-scaffold.json <<'JSON'
{"requirement_id":"REQ-2026-0001","repos":[
 {"name":"billing-api","org":"acme","visibility":"private","type":"service","description":"api","deps":[]},
 {"name":"billing-ui","org":"acme","visibility":"private","type":"web","description":"ui","deps":["billing-api"]}]}
JSON
mk REQ-2026-0001-tasks.json <<'JSON'
{"requirement_id":"REQ-2026-0001","tasks":[{"id":"t1","project":"billing-api","title":"x","tier":1,"dependencies":[],"acceptance_criteria":["a"]}]}
JSON
SJ="$WS/.collab/requirements/REQ-2026-0001-scaffold.json"; TJ="$WS/.collab/requirements/REQ-2026-0001-tasks.json"

_scaffold_validate_plan "$SJ" "$TJ" REQ-2026-0001 acme; assert_eq "valid plan ok" "0" "$?"
_scaffold_validate_plan "$SJ" "$TJ" REQ-2026-9999 acme >/dev/null 2>&1; assert_eq "req mismatch aborts" "1" "$?"
_scaffold_validate_plan "$SJ" "$TJ" REQ-2026-0001 other >/dev/null 2>&1; assert_eq "org != gitOrg aborts" "1" "$?"
# bad slug
mk bad-scaffold.json <<'JSON'
{"requirement_id":"R","repos":[{"name":"-bad","org":"acme","visibility":"private","type":"service"}]}
JSON
_scaffold_validate_plan "$WS/.collab/requirements/bad-scaffold.json" "" R acme >/dev/null 2>&1; assert_eq "bad slug aborts" "1" "$?"
# task project not in repos
mk tj2.json <<'JSON'
{"requirement_id":"REQ-2026-0001","tasks":[{"id":"t1","project":"nope","title":"x","tier":1,"dependencies":[],"acceptance_criteria":["a"]}]}
JSON
_scaffold_validate_plan "$SJ" "$WS/.collab/requirements/tj2.json" REQ-2026-0001 acme >/dev/null 2>&1; assert_eq "task project not in repos aborts" "1" "$?"
# PII
mk pii-scaffold.json <<'JSON'
{"requirement_id":"R","repos":[{"name":"api","org":"acme","visibility":"private","type":"service","description":"contact john@acme.com"}]}
JSON
_scaffold_scan_pii "$WS/.collab/requirements/pii-scaffold.json" >/dev/null 2>&1; assert_eq "PII in description aborts" "1" "$?"
_scaffold_scan_pii "$SJ"; assert_eq "clean plan passes PII" "0" "$?"

# (gate + create + register cases appended in Tasks 6-8)
rm -rf "$WS"
echo ""
if [[ $errors -eq 0 ]]; then echo "PASS: all prd-scaffold tests passed"; else echo "FAIL: $errors tests failed"; exit 1; fi
