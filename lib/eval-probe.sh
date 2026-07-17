#!/usr/bin/env bash
# Deterministic PKB probe (issue #27) — measure, don't assert.
#
# A fixed fixture project + a fixed question set exercise the shipped PKB
# selection machinery with NO LLM involved: moduleMap lookup (#21), the
# legacy-regex fallback, and staleness detection (#20). The JSON report is
# stamped with the mra commit so runs are directly comparable across commits
# — a ranking/selection regression shows up as a recall drop on the same
# cases (codegraph's evaluation-runner discipline).
#
# Usage: mra eval-probe [--out <file>]   (report JSON to file, else stdout)

eval_pkb_probe() {
  local out_file=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --out)
        if [[ $# -lt 2 ]]; then log_error "--out requires a file path" "eval"; return 1; fi
        out_file="$2"; shift 2 ;;
      *) log_error "unknown option: $1 (usage: mra eval-probe [--out <file>])" "eval"; return 1 ;;
    esac
  done

  local mra_dir mra_commit
  mra_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  mra_commit=$(git -C "$mra_dir" rev-parse --short HEAD 2>/dev/null || echo "unknown")

  local fx
  fx=$(mktemp -d)
  _probe_build_fixture "$fx" || { rm -rf "$fx"; return 1; }

  _PROBE_CASES="[]"
  _PROBE_TOTAL=0
  _PROBE_HITS=0

  # --- Selection cases (exact match) ---
  _probe_case "moduleMap: non-standard layout" \
    "chat" "$(pkb_modules_from_files "services/chat/x.ts" "$fx")"
  _probe_case "moduleMap: longest prefix wins" \
    "chat-api" "$(pkb_modules_from_files "services/chat-api/y.ts" "$fx")"
  _probe_case "fallback: legacy path regex" \
    "pay" "$(pkb_modules_from_files "src/features/pay/z.ts" "$fx")"

  # --- Staleness cases (ordered: clean before mutations) ---
  _probe_case "staleness: clean tree is fresh" \
    "" "$(pkb_stale_files "$fx")"
  printf 'alpha changed\n' >> "$fx/a.txt"
  _probe_case_contains "staleness: modification detected" \
    "a.txt" "$(pkb_stale_files "$fx")"
  rm -f "$fx/b.txt"
  _probe_case_contains "staleness: deletion detected" \
    "b.txt" "$(pkb_stale_files "$fx")"

  rm -rf "$fx"

  local recall report
  recall=$(jq -n --argjson h "$_PROBE_HITS" --argjson t "$_PROBE_TOTAL" \
    'if $t == 0 then 0 else ($h / $t) end')
  report=$(jq -n \
    --arg commit "$mra_commit" \
    --arg date "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --argjson cases "$_PROBE_CASES" \
    --argjson hits "$_PROBE_HITS" \
    --argjson total "$_PROBE_TOTAL" \
    --argjson recall "$recall" \
    '{mraCommit: $commit, date: $date, total: $total, hits: $hits, recall: $recall, cases: $cases}')

  if [[ -n "$out_file" ]]; then
    printf '%s\n' "$report" > "$out_file"
  else
    printf '%s\n' "$report"
  fi

  if [[ "$_PROBE_HITS" -eq "$_PROBE_TOTAL" ]]; then
    log_success "pkb probe: $_PROBE_HITS/$_PROBE_TOTAL cases pass (recall $recall) @ $mra_commit" "eval"
    return 0
  fi
  log_error "pkb probe: only $_PROBE_HITS/$_PROBE_TOTAL cases pass (recall $recall) @ $mra_commit" "eval"
  return 1
}

# Fixture: a git project whose layout exercises map lookup, regex fallback,
# and snapshot staleness. Rebuilt fresh per run — probe results never depend
# on machine state.
_probe_build_fixture() {
  local fx="$1"
  git -C "$fx" init -q || return 1
  git -C "$fx" config user.email probe@mra.invalid
  git -C "$fx" config user.name probe
  mkdir -p "$fx/services/chat" "$fx/services/chat-api" "$fx/src/features/pay"
  printf 'alpha\n' > "$fx/a.txt"
  printf 'beta\n' > "$fx/b.txt"
  git -C "$fx" add . && git -C "$fx" commit -qm fixture

  local pkb="$fx/.mra/pkb"
  mkdir -p "$pkb/modules"
  cat > "$pkb/meta.json" <<'EOF'
{"version":2,"moduleMap":{"chat":"services/chat","chat-api":"services/chat-api"}}
EOF
  pkb_record_snapshot "$fx"
}

_probe_case() {
  local name="$1" expected="$2" got="$3"
  local ok=false
  [[ "$got" == "$expected" ]] && ok=true
  _probe_record "$name" "$expected" "$got" "$ok"
}

_probe_case_contains() {
  local name="$1" expected_substr="$2" got="$3"
  local ok=false
  [[ "$got" == *"$expected_substr"* ]] && ok=true
  _probe_record "$name" "contains:$expected_substr" "$got" "$ok"
}

_probe_record() {
  local name="$1" expected="$2" got="$3" ok="$4"
  _PROBE_TOTAL=$((_PROBE_TOTAL + 1))
  [[ "$ok" == "true" ]] && _PROBE_HITS=$((_PROBE_HITS + 1))
  _PROBE_CASES=$(jq -c \
    --arg n "$name" --arg e "$expected" --arg g "$got" --argjson p "$ok" \
    '. + [{name: $n, expected: $e, got: $g, pass: $p}]' <<<"$_PROBE_CASES")
}
