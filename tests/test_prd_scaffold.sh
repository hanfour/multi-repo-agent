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

# repos:null must return 1 (not abort under set -e)
printf '{"requirement_id":"R","repos":null}' > "$WS/.collab/requirements/null-scaffold.json"
( set -e; _scaffold_validate_plan "$WS/.collab/requirements/null-scaffold.json" "" R acme ) >/dev/null 2>&1; assert_eq "repos:null returns 1 (no set-e abort)" "1" "$?"

# _scaffold_print_plan exits 0 and mentions a repo name
out=$( _scaffold_print_plan "$SJ" acme 2>&1 ); assert_eq "print_plan exits 0" "0" "$?"
[[ "$out" == *"billing-api"* ]] && ok "print_plan output mentions billing-api" || fail "print_plan output missing billing-api"

# (gate + create + register cases appended in Tasks 6-8)
rm -rf "$WS"

# --- pure register: additive, atomic, curated-node-untouched, idempotent ---
WS2=$(mktemp -d); mkdir -p "$WS2/.collab/requirements"
# a CURATED dep-graph with an existing repo carrying edges we must not lose
cat > "$WS2/.collab/dep-graph.json" <<'JSON'
{"gitOrg":"git@github.com:acme","projects":{"erp":{"type":"rails-api","port":3000,"deps":{},"consumedBy":["partner-api-gateway"],"confidence":{"x":1}}}}
JSON
_scaffold_register "$WS2" "billing-api" "service" "api" ""
_scaffold_register "$WS2" "billing-ui" "web" "ui" "billing-api"
# curated node byte-preserved (still has consumedBy + confidence)
assert_eq "curated erp.consumedBy preserved" "partner-api-gateway" "$(jq -r '.projects.erp.consumedBy[0]' "$WS2/.collab/dep-graph.json")"
assert_eq "curated erp.confidence preserved" "1" "$(jq -r '.projects.erp.confidence.x' "$WS2/.collab/dep-graph.json")"
# new nodes added in init shape
assert_eq "billing-api node type" "service" "$(jq -r '.projects["billing-api"].type' "$WS2/.collab/dep-graph.json")"
assert_eq "billing-api init shape port null" "null" "$(jq -r '.projects["billing-api"].port' "$WS2/.collab/dep-graph.json")"
# manual-deps + repos.json created (were absent) and populated
assert_eq "manual-deps edge ui->api" "billing-api" "$(jq -r '.[]|select(.source=="billing-ui").target' "$WS2/.collab/manual-deps.json")"
assert_eq "repos.json entry" "billing-ui" "$(jq -r '.repos[]|select(.name=="billing-ui").name' "$WS2/.collab/repos.json")"
# idempotent: re-run adds nothing
before=$(jq '.projects|length' "$WS2/.collab/dep-graph.json")
_scaffold_register "$WS2" "billing-api" "service" "api" ""
assert_eq "register idempotent (no dup node)" "$before" "$(jq '.projects|length' "$WS2/.collab/dep-graph.json")"
assert_eq "register idempotent (no dup repo)" "1" "$(jq '[.repos[]|select(.name=="billing-api")]|length' "$WS2/.collab/repos.json")"
# scope written
_scaffold_write_scope "$WS2" REQ-2026-0002 billing-api billing-ui
assert_eq "scope file content" "billing-api billing-ui" "$(cat "$WS2/.collab/requirements/REQ-2026-0002-scope")"
rm -rf "$WS2"
echo ""
if [[ $errors -eq 0 ]]; then echo "PASS: all prd-scaffold tests passed"; else echo "FAIL: $errors tests failed"; exit 1; fi
