#!/usr/bin/env bash
# canonical 規則檔的 schema 與驗證 (lib/rule-schema.sh)。
#
# 兩條萃取路線（TF-IDF 分群、finding 分類）的產出都要通過這一套驗證，否則
# 最後比較的可能是格式差異而不是規則品質。這支測試因此不只驗「合格 fixture
# 通過」，還逐一驗每種不合格的形狀都能被抓到，而且驗證一次要報所有問題，
# 不是遇到第一個就停——萃取階段一次會產幾十個檔，一次看到全部問題比修一個
# 跑一次快得多。
set -uo pipefail
MRA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$MRA_DIR/lib/corpus-targets.sh"
source "$MRA_DIR/lib/rule-schema.sh"

errors=0; pass=0
ok()   { echo "PASS: $1"; pass=$((pass+1)); }
fail() { echo "FAIL: $1"; errors=$((errors+1)); }
eq()   { if [[ "$2" == "$3" ]]; then ok "$1"; else fail "$1 — expected [$2] got [$3]"; fi; }
has()  { case "$2" in *"$3"*) ok "$1" ;; *) fail "$1 — 沒看到「$3」：$2" ;; esac; }
lacks(){ case "$2" in *"$3"*) fail "$1 — 不該看到「$3」：$2" ;; *) ok "$1" ;; esac; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/rule-schema-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

FIX="$MRA_DIR/tests/fixtures/rules"

test_valid_fixture_passes() {
  rule_validate "$FIX/valid-example.md" 2>"$TMP/err" && ok "合格 fixture 通過" \
    || fail "合格 fixture 應該通過：$(cat "$TMP/err")"
}

test_missing_frontmatter_field() {
  sed '/^severity_default:/d' "$FIX/valid-example.md" > "$TMP/no-sev.md"
  local out; out="$(rule_validate "$TMP/no-sev.md" 2>&1)"
  local rc=$?
  [ "$rc" -ne 0 ] && ok "缺 severity_default 不通過" || fail "應該不通過"
  has "訊息指名缺哪個欄位" "$out" "severity_default"
}

test_missing_section() {
  # 砍掉「反例」整段
  awk '/^## 反例/{skip=1} /^## 出處/{skip=0} !skip' "$FIX/valid-example.md" > "$TMP/no-counter.md"
  local out; out="$(rule_validate "$TMP/no-counter.md" 2>&1)"
  local rc=$?
  [ "$rc" -ne 0 ] && ok "缺反例章節不通過" || fail "應該不通過"
  has "訊息指名缺哪個章節" "$out" "反例"
}

test_source_count_below_three() {
  # 只留兩則出處
  sed '/discussion_r100003/d' "$FIX/valid-example.md" > "$TMP/two-src.md"
  local out; out="$(rule_validate "$TMP/two-src.md" 2>&1)"
  local rc=$?
  [ "$rc" -ne 0 ] && ok "出處只有兩則不通過" || fail "應該不通過"
  has "訊息說出處不足" "$out" "出處"
  eq "rule_source_count 算出 2" "2" "$(rule_source_count "$TMP/two-src.md")"
}

test_severity_default_must_be_known() {
  sed 's/^severity_default: HIGH/severity_default: URGENT/' "$FIX/valid-example.md" > "$TMP/bad-sev.md"
  local out; out="$(rule_validate "$TMP/bad-sev.md" 2>&1)"
  local rc=$?
  [ "$rc" -ne 0 ] && ok "不認得的 severity 不通過" || fail "應該不通過"
  has "訊息指名不合法的值" "$out" "URGENT"
}

test_id_must_match_filename() {
  cp "$FIX/valid-example.md" "$TMP/wrong-name.md"
  local out; out="$(rule_validate "$TMP/wrong-name.md" 2>&1)"
  local rc=$?
  [ "$rc" -ne 0 ] && ok "id 與檔名不符不通過" || fail "應該不通過"
  has "訊息說明 id 與檔名要一致" "$out" "wrong-name"
}

test_layer_must_be_known() {
  sed 's/^layer: nestjs/layer: golang/' "$FIX/valid-example.md" > "$TMP/bad-layer.md"
  local out; out="$(rule_validate "$TMP/bad-layer.md" 2>&1)"
  local rc=$?
  [ "$rc" -ne 0 ] && ok "不認得的 layer 不通過" || fail "應該不通過"
  has "訊息列出合法的 layer" "$out" "nestjs"
}

test_section_extraction() {
  local body; body="$(rule_section "$FIX/valid-example.md" "判準")"
  has "判準章節抓得到內容" "$body" "request-scoped provider"
  lacks "判準章節不含下一節的內容" "$body" "CRITICAL："
}

# 每個問題各報一次，不要遇到第一個就中止 —— 萃取階段一次會產幾十個檔，
# 一次看到全部問題比修一個跑一次快得多。
test_reports_all_problems_at_once() {
  sed -e '/^severity_default:/d' -e '/discussion_r100003/d' \
    "$FIX/valid-example.md" > "$TMP/two-problems.md"
  local out; out="$(rule_validate "$TMP/two-problems.md" 2>&1)"
  has "同時報 severity_default" "$out" "severity_default"
  has "同時報出處不足" "$out" "出處"
}

# 額外案例：不在 brief 裡，但補上以驗證 rule_field / rule_frontmatter 的
# 基本取值行為，是後續 rule_render_block 依賴的介面。
test_rule_field_extracts_scalar() {
  eq "rule_field 取得 id" "valid-example" "$(rule_field "$FIX/valid-example.md" id)"
  eq "rule_field 取得 layer" "nestjs" "$(rule_field "$FIX/valid-example.md" layer)"
  eq "rule_field 取得 severity_default" "HIGH" "$(rule_field "$FIX/valid-example.md" severity_default)"
}

test_rule_field_missing_key_returns_empty_and_nonzero() {
  local out; out="$(rule_field "$FIX/valid-example.md" no_such_field)"
  local rc=$?
  eq "缺欄位印出空字串" "" "$out"
  [ "$rc" -eq 1 ] && ok "缺欄位退出碼是 1" || fail "應該回傳退出碼 1，得到 $rc"
}

test_valid_fixture_passes
test_missing_frontmatter_field
test_missing_section
test_source_count_below_three
test_severity_default_must_be_known
test_id_must_match_filename
test_layer_must_be_known
test_section_extraction
test_reports_all_problems_at_once
test_rule_field_extracts_scalar
test_rule_field_missing_key_returns_empty_and_nonzero

echo "---"; echo "Passed: $pass"; echo "Failed: $errors"
exit $((errors > 0 ? 1 : 0))
