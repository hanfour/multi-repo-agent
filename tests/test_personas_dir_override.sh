#!/usr/bin/env bash
# 讓 persona 目錄可覆寫 (lib/personas.sh 的 _personas_dir())。
#
# 這支檔案是 review 主流程用的，Slack gateway 也會走到，所以預設行為完全
# 不變是硬要求——test_default_unchanged 之外，這支測試也要能被
# tests/test_review_*.sh 全套一起跑，不能只看這支自己過。
set -uo pipefail
MRA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$MRA_DIR/lib/personas.sh"

errors=0; pass=0
ok()   { echo "PASS: $1"; pass=$((pass+1)); }
fail() { echo "FAIL: $1"; errors=$((errors+1)); }
eq()   { if [[ "$2" == "$3" ]]; then ok "$1"; else fail "$1 — expected [$2] got [$3]"; fi; }
has()  { case "$2" in *"$3"*) ok "$1" ;; *) fail "$1 — 沒看到「$3」：$2" ;; esac; }
lacks(){ case "$2" in *"$3"*) fail "$1 — 不該看到「$3」：$2" ;; *) ok "$1" ;; esac; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/personas-dir-override-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

test_default_unchanged() {
  unset MRA_PERSONAS_DIR
  local d; d="$(_personas_dir)"
  has "預設指向 agents/personas" "$d" "agents/personas"
}

test_env_override_takes_effect() {
  mkdir -p "$TMP/custom"
  local d; d="$(MRA_PERSONAS_DIR="$TMP/custom" _personas_dir)"
  eq "env 覆蓋生效" "$TMP/custom" "$d"
}

# 指到不存在的目錄時要硬失敗，不是退回內建的 agents/personas：退回去的話，
# 一輪帶規則的回測會用沒有注入規則的 persona 跑完，summary 一切正常，然後被
# 拿去跟基準線比較——比的其實是同一組 persona。警告攔不住這件事，回測把每個
# PR 的 stderr 導進各自的 .err 檔，沒有東西在解析它。
test_nonexistent_override_fails_hard() {
  local out d rc
  d="$(MRA_PERSONAS_DIR="$TMP/does-not-exist" _personas_dir 2>"$TMP/warn")"
  rc=$?
  out="$(cat "$TMP/warn")"
  [ "$rc" -ne 0 ] && ok "指不到目錄時退出碼非 0" || fail "必須硬失敗，不能退回預設"
  eq "不印出任何路徑（不讓呼叫端誤用）" "" "$d"
  has "印出 PERSONAS_DIR_INVALID" "$out" "PERSONAS_DIR_INVALID"
}

# load_persona 要把這個失敗傳出去，不能自己吞掉再去讀內建的那一份。
test_load_persona_propagates_invalid_dir() {
  local rc
  MRA_PERSONAS_DIR="$TMP/does-not-exist" load_persona security-auditor \
    >/dev/null 2>"$TMP/warn-load"
  rc=$?
  [ "$rc" -ne 0 ] && ok "load_persona 在覆蓋無效時退出碼非 0" || fail "load_persona 必須傳出失敗"
  has "印出 PERSONAS_DIR_INVALID" "$(cat "$TMP/warn-load")" "PERSONAS_DIR_INVALID"
}

# list_personas 同理。它回 0 加空清單的話，呼叫端會以為「這個目錄裡沒有
# persona」，跟「路徑根本不對」分不出來。
test_list_personas_propagates_invalid_dir() {
  local rc
  MRA_PERSONAS_DIR="$TMP/does-not-exist" list_personas >/dev/null 2>&1
  rc=$?
  [ "$rc" -ne 0 ] && ok "list_personas 在覆蓋無效時退出碼非 0" || fail "list_personas 必須傳出失敗"
}

test_load_persona_reads_from_override() {
  mkdir -p "$TMP/custom"
  printf 'ROLE: Custom\nFOCUS:\n- x\n' > "$TMP/custom/security-auditor.md"
  local body; body="$(MRA_PERSONAS_DIR="$TMP/custom" load_persona security-auditor)"
  has "讀到覆蓋目錄的內容" "$body" "ROLE: Custom"
}

# 畸形輸入：override 是檔案而不是目錄，跟指不到一樣要硬失敗，不是把
# load_persona 拖去對著一個檔案做 dirname 之類的意外行為。
test_override_pointing_at_a_file_fails_hard() {
  printf 'not a directory\n' > "$TMP/not-a-dir"
  local out d rc
  d="$(MRA_PERSONAS_DIR="$TMP/not-a-dir" _personas_dir 2>"$TMP/warn2")"
  rc=$?
  out="$(cat "$TMP/warn2")"
  [ "$rc" -ne 0 ] && ok "指向檔案時退出碼非 0" || fail "必須硬失敗，不能退回預設"
  eq "不印出任何路徑" "" "$d"
  has "印出 PERSONAS_DIR_INVALID" "$out" "PERSONAS_DIR_INVALID"
}

# 畸形輸入：override 顯式設成空字串，跟「沒設」等價，不該印警告（不是打錯
# 路徑，是呼叫端刻意的 no-op）。
test_empty_override_is_treated_as_unset() {
  local out d
  d="$(MRA_PERSONAS_DIR="" _personas_dir 2>"$TMP/warn3")"
  out="$(cat "$TMP/warn3")"
  has "退回預設路徑" "$d" "agents/personas"
  eq "空字串不算打錯路徑，不印警告" "" "$out"
}

# 覆蓋目錄存在，但目標 persona 檔不存在：load_persona 該報「找不到」而不是
# 靜默印出空字串或讀到別的 persona。
test_load_persona_missing_file_in_override_still_fails_loudly() {
  mkdir -p "$TMP/custom-missing"
  local out rc
  out="$(MRA_PERSONAS_DIR="$TMP/custom-missing" load_persona security-auditor 2>&1)"
  rc=$?
  [ "$rc" -ne 0 ] && ok "覆蓋目錄裡沒有這個 persona 時退出碼非 0" || fail "應退出非 0"
  has "印出 persona not found" "$out" "persona not found"
}

# =============================================================================
# 靜態檢查：這個專案已經為「2>/dev/null 吞掉診斷」付過四次代價，鎖住
# lib/personas.sh 裡不會出現這個模式。
# =============================================================================
test_lib_never_discards_stderr_with_dev_null() {
  lacks "lib/personas.sh 沒有 2>/dev/null" \
    "$(cat "$MRA_DIR/lib/personas.sh")" "2>/dev/null"
}

test_default_unchanged
test_env_override_takes_effect
test_nonexistent_override_fails_hard
test_load_persona_propagates_invalid_dir
test_list_personas_propagates_invalid_dir
test_load_persona_reads_from_override
test_override_pointing_at_a_file_fails_hard
test_empty_override_is_treated_as_unset
test_load_persona_missing_file_in_override_still_fails_loudly
test_lib_never_discards_stderr_with_dev_null

echo "---"; echo "Passed: $pass"; echo "Failed: $errors"
exit $((errors > 0 ? 1 : 0))
