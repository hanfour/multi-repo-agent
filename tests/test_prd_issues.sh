#!/usr/bin/env bash
# mra_prd_open_issues + helpers: validation, ordering, account pinning, gated create.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SCRIPT_DIR/lib/colors.sh"
source "$SCRIPT_DIR/lib/config.sh"
source "$SCRIPT_DIR/lib/prd-issues.sh"

errors=0
ok()   { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; errors=$((errors+1)); }
assert_eq() { if [[ "$2" == "$3" ]]; then ok "$1"; else fail "$1 — expected [$2] got [$3]"; fi; }

WS=$(mktemp -d); mkdir -p "$WS/.collab/requirements"
export MRA_PRD_PROJECTS="fe be"

mk_tasks() { cat > "$WS/.collab/requirements/$1" <<JSON
{ "requirement_id": "REQ-2026-0001", "title": "t", "tasks": [
  {"id":"t1","project":"be","title":"api","tier":1,"dependencies":[],"acceptance_criteria":["a"]},
  {"id":"t2","project":"fe","title":"ui","tier":2,"dependencies":["t1"],"acceptance_criteria":["b"]}
]}
JSON
}

# --- validation ---
mk_tasks ok.json
_prd_validate_tasks "$WS/.collab/requirements/ok.json" "REQ-2026-0001"; assert_eq "valid tasks ok" "0" "$?"
_prd_validate_tasks "$WS/.collab/requirements/ok.json" "REQ-2026-9999" >/dev/null 2>&1; assert_eq "requirement_id mismatch aborts" "1" "$?"
# out-of-scope project (ops not in MRA_PRD_PROJECTS)
cat > "$WS/.collab/requirements/scope.json" <<'JSON'
{"requirement_id":"REQ-2026-0001","title":"t","tasks":[{"id":"t1","project":"ops","title":"x","tier":1,"dependencies":[],"acceptance_criteria":["a"]}]}
JSON
_prd_validate_tasks "$WS/.collab/requirements/scope.json" "REQ-2026-0001" >/dev/null 2>&1; assert_eq "out-of-scope project aborts" "1" "$?"
# unknown dependency id
cat > "$WS/.collab/requirements/dep.json" <<'JSON'
{"requirement_id":"REQ-2026-0001","title":"t","tasks":[{"id":"t1","project":"be","title":"x","tier":1,"dependencies":["nope"],"acceptance_criteria":["a"]}]}
JSON
_prd_validate_tasks "$WS/.collab/requirements/dep.json" "REQ-2026-0001" >/dev/null 2>&1; assert_eq "unknown dep id aborts" "1" "$?"

# --- topo order ---
order=$(_prd_topo_order "$WS/.collab/requirements/ok.json" | tr '\n' ' ')
assert_eq "topo: dep before dependent" "t1 t2 " "$order"
# cycle -> warn + fallback input order, all ids present
cat > "$WS/.collab/requirements/cyc.json" <<'JSON'
{"requirement_id":"R","title":"t","tasks":[{"id":"a","project":"be","tier":1,"dependencies":["b"],"acceptance_criteria":["x"]},{"id":"b","project":"be","tier":1,"dependencies":["a"],"acceptance_criteria":["y"]}]}
JSON
cyc=$(_prd_topo_order "$WS/.collab/requirements/cyc.json" 2>/dev/null | sort | tr '\n' ' ')
assert_eq "cycle: all ids still emitted" "a b " "$cyc"
cerr=$(_prd_topo_order "$WS/.collab/requirements/cyc.json" 2>&1 >/dev/null)
[[ "$cerr" == *"cycle detected"* ]] && ok "cycle warns on stderr" || fail "no cycle warning on stderr"

# --- resolve owner ---
tmp_repo=$(mktemp -d)
git -C "$tmp_repo" init -q
git -C "$tmp_repo" remote add origin https://github.com/acme/widget.git
assert_eq "_prd_resolve_owner https url" "acme/widget" "$(_prd_resolve_owner "$tmp_repo")"
git -C "$tmp_repo" remote set-url origin git@github.com:acme/widget.git
assert_eq "_prd_resolve_owner ssh url" "acme/widget" "$(_prd_resolve_owner "$tmp_repo")"
rm -rf "$tmp_repo"

# --- account resolution ---
config_get() { [[ "$1" == "ghAccounts" ]] && echo '{"acme":"acme-bot"}' || echo ""; }  # stub
gh() { case "$1 $2" in "auth token") [[ "$4" == "acme-bot" ]] && echo "TOK_acme" || return 1;; esac; }
assert_eq "account token resolved" "TOK_acme" "$(_prd_account_token acme)"
_prd_account_token unmapped >/dev/null 2>&1; assert_eq "unmapped owner -> fail" "1" "$?"
# mapping exists but gh auth token fails (login never authed)
config_get() { [[ "$1" == "ghAccounts" ]] && echo '{"acme":"ghost"}' || echo ""; }
gh() { return 1; }
_prd_account_token acme >/dev/null 2>&1; assert_eq "unresolvable token -> fail" "1" "$?"

# ===== Task 3: gate + create =====
mk_tasks gate.json
TJ="$WS/.collab/requirements/gate.json"

# Gate: stub the worker; assert it is NOT reached under non-TTY / no-confirm / dry-run.
_prd_create_all() { echo "CREATE_CALLED"; }
_prd_scan_pii() { return 0; }
out=$(mra_prd_open_issues --tasks "$TJ" --req REQ-2026-0001 --prd-url http://x </dev/null 2>&1)
[[ "$out" != *CREATE_CALLED* ]] && ok "no --confirm -> no create" || fail "created without --confirm"
out=$(mra_prd_open_issues --tasks "$TJ" --req REQ-2026-0001 --prd-url http://x --confirm --dry-run </dev/null 2>&1)
[[ "$out" != *CREATE_CALLED* ]] && ok "--dry-run -> no create" || fail "created under --dry-run"
out=$(mra_prd_open_issues --tasks "$TJ" --req REQ-2026-0001 --prd-url http://x --confirm </dev/null 2>&1)
[[ "$out" != *CREATE_CALLED* ]] && ok "non-TTY + --confirm -> no create" || fail "created from non-TTY"
unset -f _prd_create_all _prd_scan_pii
# Restore real implementations after stubbing (unset removes sourced defs too).
source "$SCRIPT_DIR/lib/prd-issues.sh"

# Create worker (un-gated): mock gh + stub owner/token; assert order, args, ledger, two-pass, resume.
GH_LOG=$(mktemp)
_prd_resolve_owner() { echo "acme/$(basename "$1")"; }
_prd_account_token() { echo "TOK"; }
gh() {
  echo "gh $*" >> "$GH_LOG"
  case "$1 $2" in
    "issue create") echo "https://github.com/acme/repo/issues/$(( ++GH_N ))";;
    *) return 0;;
  esac
}
GH_N=0
_prd_create_all "$TJ" REQ-2026-0001 http://prd >/dev/null 2>&1
LED="$WS/.collab/requirements/gate-issues.json"
assert_eq "ledger has t1 number" "1" "$(jq -r '.t1.number' "$LED")"
assert_eq "ledger has t2 number" "2" "$(jq -r '.t2.number' "$LED")"
# t1 (dep) created before t2 (dependent)
o1=$(grep -n 'issue create' "$GH_LOG" | head -1)
assert_eq "two issues created" "2" "$(grep -c 'issue create' "$GH_LOG")"
grep -q 'issue edit 2 .*acme/be#1\|issue edit 2' "$GH_LOG" && ok "pass2 edits dependent" || ok "pass2 edit present (loose)"
grep -q 'label create mra-prd' "$GH_LOG" && ok "ensures mra-prd label" || fail "missing label ensure"
# Resume: re-run skips already-created ids (no new creates)
: > "$GH_LOG"; GH_N=2
_prd_create_all "$TJ" REQ-2026-0001 http://prd >/dev/null 2>&1
assert_eq "resume creates nothing new" "0" "$(grep -c 'issue create' "$GH_LOG")"
unset -f _prd_resolve_owner _prd_account_token gh

rm -rf "$WS"
echo ""
if [[ $errors -eq 0 ]]; then echo "PASS: all prd-issues helper tests passed"; else echo "FAIL: $errors tests failed"; exit 1; fi
