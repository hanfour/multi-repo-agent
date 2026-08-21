#!/usr/bin/env bash
# 帶規則回測 (scripts/run-rule-backtest.sh)。用 stub 取代
# scripts/run-backtest.sh，只驗流程（先驗規則、注入、傳對執行條件），不驗
# review 品質、不呼叫任何 LLM、不連網路。
#
# 這支測試特別針對三件「brief 參考實作沒處理好」的事各補一組測試：
#   1. brief 原本沒有任何管道能覆寫注入的 token 預算（rule_inject_all 只被
#      呼叫成三個參數，永遠用 lib 內建的預設值），但這正是這個 Task 要求的
#      能力——見 --token-budget 那組測試，順帶驗證真的傳到了
#      rule_render_block（用觀察得到的注入內容證明，不是猜測）。
#   2. brief 原本完全沒有任何地方回報「幾個 persona 真的拿到規則」，而
#      agents/personas/test-architect.md 沒有 FOCUS 錨點是這個專案已知、
#      刻意不修的事實（修了會讓基準線 C 不可比）——這裡驗證訊息確實印出
#      「4/5」，並且寫進執行條件記錄裡，不是只印在 stdout 上跑完就沒了。
#   3. brief 用 `ls ... 2>/dev/null | wc -l` 判斷 NO_RULES，會把「目錄不
#      存在」跟「目錄存在但是空的」混在一起，而且丟掉 ls 本身的診斷——這裡
#      用畸形輸入（--rules 指到一個檔案、指到只有非 .md 檔案的目錄）拆穿
#      任何退化成「只檢查非空」的實作。
set -uo pipefail
MRA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$MRA_DIR/lib/corpus-targets.sh"
source "$MRA_DIR/lib/rule-schema.sh"
source "$MRA_DIR/lib/rule-inject.sh"

S="$MRA_DIR/scripts/run-rule-backtest.sh"
FIX="$MRA_DIR/tests/fixtures/rule-inject"

errors=0; pass=0
ok()   { echo "PASS: $1"; pass=$((pass+1)); }
fail() { echo "FAIL: $1"; errors=$((errors+1)); }
eq()   { if [[ "$2" == "$3" ]]; then ok "$1"; else fail "$1 — expected [$2] got [$3]"; fi; }
has()  { case "$2" in *"$3"*) ok "$1" ;; *) fail "$1 — 沒看到「$3」：$2" ;; esac; }
lacks(){ case "$2" in *"$3"*) fail "$1 — 不該看到「$3」：$2" ;; *) ok "$1" ;; esac; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/run-rule-backtest-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

STUB="$TMP/stub"
mkdir -p "$STUB"
export MRA_BENCHMARK_DIR="$TMP/bench"
mkdir -p "$MRA_BENCHMARK_DIR"

# write_backtest_stub — 假造 scripts/run-backtest.sh：把收到的 argv 與
# 這個測試在意的環境變數都寫進紀錄檔，不真的跑 review。
write_backtest_stub() {
  cat > "$STUB/backtest" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" > "$STUB/argv.log"
{
  printf 'MRA_PERSONAS_DIR=%s\n' "\${MRA_PERSONAS_DIR:-<unset>}"
  printf 'MRA_REVIEW_PERSONA_MAX_TURNS=%s\n' "\${MRA_REVIEW_PERSONA_MAX_TURNS:-<unset>}"
  printf 'MRA_BACKTEST_REVIEW_MODE=%s\n' "\${MRA_BACKTEST_REVIEW_MODE:-<unset>}"
  printf 'MRA_BACKTEST_CMD=%s\n' "\${MRA_BACKTEST_CMD:-<unset>}"
} > "$STUB/env.log"
exit 0
SH
  chmod +x "$STUB/backtest"
}

reset_stub_logs() {
  rm -f "$STUB/argv.log" "$STUB/env.log"
}

# write_common_rule <dir> <id> <n_sources> — 一份格式合格、layer=common、
# 出處數可控的規則檔，給 token 預算覆寫測試用（run-rule-backtest.sh 一律用
# common 層注入，所以這裡固定 layer=common，不像 test_rule_inject.sh 的
# write_rank_rule 需要支援任意層）。
write_common_rule() {
  local dir="$1" id="$2" n="$3"
  mkdir -p "$dir"
  {
    printf -- '---\n'
    printf 'id: %s\n' "$id"
    printf 'layer: common\n'
    printf 'frameworks: ["*"]\n'
    printf 'severity_default: MEDIUM\n'
    printf -- '---\n'
    printf '## 觸發訊號\n測試觸發 %s。\n\n' "$id"
    printf '## 判準\n測試判準 %s。\n\n' "$id"
    printf '## 嚴重度\nMEDIUM：測試用。\n\n'
    printf '## 反例（不該報）\n測試反例 %s。\n\n' "$id"
    printf '## 出處\n'
    local i
    for ((i = 1; i <= n; i++)); do
      printf -- '- https://example.com/repo/pull/%d#discussion_r%d\n' "$i" "$((900000 + i))"
    done
  } > "$dir/$id.md"
}

# ---------------------------------------------------------------------------
# 基本流程：注入在呼叫 backtest 之前、環境變數傳對
# ---------------------------------------------------------------------------

test_injects_before_running_backtest() {
  write_backtest_stub
  reset_stub_logs
  MRA_BACKTEST_SCRIPT="$STUB/backtest" MRA_RULE_PERSONA_DIR="$TMP" \
    bash "$S" --rules "$FIX/rules" --label rules-test >/dev/null 2>&1
  local injected="$TMP/personas-rules-test/security-auditor.md"
  [ -f "$injected" ] && ok "產出了注入後的 persona" || fail "沒有注入後的 persona"
  has "注入後含 RULESET" "$(cat "$injected")" "BEGIN RULESET"
}

test_points_persona_dir_at_injected_copy() {
  has "MRA_PERSONAS_DIR 指向注入後的目錄" "$(cat "$STUB/env.log")" "personas-rules-test"
  lacks "MRA_PERSONAS_DIR 不是原本的 agents/personas" \
    "$(cat "$STUB/env.log")" "MRA_PERSONAS_DIR=$MRA_DIR/agents/personas"
}

test_passes_persona_turns_20() {
  has "persona 輪數與階段二的 C 一致" "$(cat "$STUB/env.log")" "MRA_REVIEW_PERSONA_MAX_TURNS=20"
}

test_passes_review_mode_personas() {
  has "review 模式傳了 personas" "$(cat "$STUB/env.log")" "MRA_BACKTEST_REVIEW_MODE=personas"
}

test_defaults_backtest_cmd_to_adapter_when_unset() {
  has "MRA_BACKTEST_CMD 預設指向 adapter" \
    "$(cat "$STUB/env.log")" "MRA_BACKTEST_CMD=$MRA_DIR/scripts/backtest-review-adapter.sh"
}

test_tolerance_is_passed_through() {
  reset_stub_logs
  MRA_BACKTEST_SCRIPT="$STUB/backtest" MRA_RULE_PERSONA_DIR="$TMP" \
    bash "$S" --rules "$FIX/rules" --label t15 --tolerance 15 >/dev/null 2>&1
  has "容差有傳下去" "$(cat "$STUB/argv.log")" "--tolerance 15"
}

test_default_tolerance_is_5_when_not_given() {
  reset_stub_logs
  MRA_BACKTEST_SCRIPT="$STUB/backtest" MRA_RULE_PERSONA_DIR="$TMP" \
    bash "$S" --rules "$FIX/rules" --label t-default >/dev/null 2>&1
  has "沒給 --tolerance 時預設 5" "$(cat "$STUB/argv.log")" "--tolerance 5"
}

test_label_is_passed_through() {
  has "label 有傳下去" "$(cat "$STUB/argv.log")" "--label t-default"
}

# ---------------------------------------------------------------------------
# 先驗規則再跑：不合格就不該呼叫 backtest，也不該有注入的副作用
# ---------------------------------------------------------------------------

test_refuses_when_rules_dir_empty() {
  reset_stub_logs
  mkdir -p "$TMP/no-rules"
  local out rc
  out="$(MRA_BACKTEST_SCRIPT="$STUB/backtest" MRA_RULE_PERSONA_DIR="$TMP" \
    bash "$S" --rules "$TMP/no-rules" --label x 2>&1)"; rc=$?
  [ "$rc" -ne 0 ] && ok "空規則集退出碼非 0" || fail "應退出非 0"
  has "印出 NO_RULES" "$out" "NO_RULES"
  [ ! -f "$STUB/argv.log" ] && ok "空規則集不呼叫 backtest" || fail "不該呼叫 backtest"
  [ ! -d "$TMP/personas-x" ] && ok "空規則集不產生注入副作用" || fail "不該有注入副作用"
}

# 畸形輸入：目錄裡有檔案，但一個 .md 都沒有——不能退化成「目錄非空就放行」。
test_refuses_when_rules_dir_has_no_md_files() {
  reset_stub_logs
  mkdir -p "$TMP/txt-only-rules"
  printf 'not markdown\n' > "$TMP/txt-only-rules/notes.txt"
  local out rc
  out="$(MRA_BACKTEST_SCRIPT="$STUB/backtest" bash "$S" \
    --rules "$TMP/txt-only-rules" --label txtonly 2>&1)"; rc=$?
  [ "$rc" -ne 0 ] && ok "只有非 .md 檔案時退出碼非 0" || fail "應退出非 0"
  has "印出 NO_RULES" "$out" "NO_RULES"
  [ ! -f "$STUB/argv.log" ] && ok "沒有呼叫 backtest" || fail "不該呼叫 backtest"
}

# 畸形輸入：--rules 指到一個檔案，不是目錄。
test_refuses_when_rules_path_is_a_file() {
  reset_stub_logs
  printf 'x\n' > "$TMP/a-file"
  local out rc
  out="$(MRA_BACKTEST_SCRIPT="$STUB/backtest" bash "$S" \
    --rules "$TMP/a-file" --label file-path 2>&1)"; rc=$?
  [ "$rc" -ne 0 ] && ok "--rules 指到檔案時退出碼非 0" || fail "應退出非 0"
  has "印出 NO_RULES" "$out" "NO_RULES"
  [ ! -f "$STUB/argv.log" ] && ok "沒有呼叫 backtest" || fail "不該呼叫 backtest"
}

# 沒驗證過的規則不該拿去跑——跑完才發現規則格式壞掉等於白燒幾小時。
test_validates_rules_before_running() {
  reset_stub_logs
  mkdir -p "$TMP/bad-rules"
  printf 'not a rule file\n' > "$TMP/bad-rules/x.md"
  local out rc
  out="$(MRA_BACKTEST_SCRIPT="$STUB/backtest" MRA_RULE_PERSONA_DIR="$TMP" \
    bash "$S" --rules "$TMP/bad-rules" --label y 2>&1)"; rc=$?
  [ "$rc" -ne 0 ] && ok "規則不合格退出碼非 0" || fail "應退出非 0"
  has "印出 RULES_INVALID" "$out" "RULES_INVALID"
  [ ! -f "$STUB/argv.log" ] && ok "沒有呼叫 backtest" || fail "不該呼叫 backtest"
  [ ! -d "$TMP/personas-y" ] && ok "規則不合格不產生注入副作用" || fail "不該有注入副作用"
}

# 畸形輸入：規則目錄裡有合格跟不合格的混在一起——RULES_INVALID 的計數要準,
# 不能只籠統報「有問題」,也不能因為有合格的檔案就放行整批。
test_partial_invalid_rules_reports_correct_count_and_blocks() {
  reset_stub_logs
  mkdir -p "$TMP/mixed-rules"
  write_common_rule "$TMP/mixed-rules" mixed-good-one 5
  write_common_rule "$TMP/mixed-rules" mixed-good-two 4
  printf 'not a rule file\n' > "$TMP/mixed-rules/mixed-bad.md"
  local out rc
  out="$(MRA_BACKTEST_SCRIPT="$STUB/backtest" bash "$S" \
    --rules "$TMP/mixed-rules" --label mixed 2>&1)"; rc=$?
  [ "$rc" -ne 0 ] && ok "混合合格/不合格時退出碼非 0" || fail "應退出非 0"
  has "印出 RULES_INVALID 且計數是 1/3" "$out" "RULES_INVALID：1/3"
  [ ! -f "$STUB/argv.log" ] && ok "沒有呼叫 backtest" || fail "不該呼叫 backtest"
}

# ---------------------------------------------------------------------------
# CLI 畸形輸入：缺參數、缺值、不認得的旗標
# ---------------------------------------------------------------------------

test_missing_rules_and_label_rejected() {
  local out rc
  out="$(bash "$S" 2>&1)"; rc=$?
  [ "$rc" -ne 0 ] && ok "什麼參數都沒給時退出碼非 0" || fail "應退出非 0"
}

test_empty_label_is_treated_as_missing() {
  local out rc
  out="$(bash "$S" --rules "$FIX/rules" --label "" 2>&1)"; rc=$?
  [ "$rc" -ne 0 ] && ok "--label 給空字串時退出碼非 0" || fail "應退出非 0"
}

test_flag_missing_value_rejected_not_crashed() {
  local out rc
  out="$(bash "$S" --rules "$FIX/rules" --label 2>&1)"; rc=$?
  [ "$rc" -ne 0 ] && ok "旗標缺值時退出碼非 0" || fail "應退出非 0"
  lacks "不是 bash 自己的 unbound variable 錯誤" "$out" "unbound variable"
}

test_unknown_flag_rejected() {
  local out rc
  out="$(bash "$S" --rules "$FIX/rules" --label z --bogus flag 2>&1)"; rc=$?
  [ "$rc" -ne 0 ] && ok "不認得的旗標時退出碼非 0" || fail "應退出非 0"
}

# ---------------------------------------------------------------------------
# token 預算：可覆寫，且真的傳到 rule_render_block
# ---------------------------------------------------------------------------

# 用「出處數最高的規則自己的大小」當預算：只有轉傳真的生效，注入內容才會
# 剛好只留下那一條、排除出處數較低的那條（跟
# tests/test_rule_inject.sh 的 test_render_block_takes_highest_ranked_rule_first
# 同一個手法，這裡是黑盒驗證，不是直接呼叫 rule_render_block）。
test_token_budget_flag_overrides_and_is_forwarded() {
  reset_stub_logs
  local dir="$TMP/budget-rules"
  write_common_rule "$dir" budget-cli-many 10
  write_common_rule "$dir" budget-cli-few 3
  local tiny_budget
  tiny_budget=$(( $(_rule_char_count "$(_rule_entry_text "$dir/budget-cli-many.md")") / 2 ))
  MRA_BACKTEST_SCRIPT="$STUB/backtest" MRA_RULE_PERSONA_DIR="$TMP" \
    bash "$S" --rules "$dir" --label budget-cli --token-budget "$tiny_budget" >/dev/null 2>&1
  local body; body="$(cat "$TMP/personas-budget-cli/security-auditor.md")"
  has "出處數最高的規則入選（--token-budget 生效）" "$body" "[budget-cli-many]"
  lacks "出處數較低的規則被排除（超過轉傳的小預算）" "$body" "[budget-cli-few]"
}

test_token_budget_env_var_sets_default_when_no_flag() {
  reset_stub_logs
  MRA_RULE_TOKEN_BUDGET=1234 MRA_BACKTEST_SCRIPT="$STUB/backtest" MRA_RULE_PERSONA_DIR="$TMP" \
    bash "$S" --rules "$FIX/rules" --label budget-env >/dev/null 2>&1
  local cond="$MRA_BENCHMARK_DIR/runs/budget-env/rule-inject-conditions.json"
  [ -f "$cond" ] && ok "budget-env 產生了執行條件記錄" || fail "沒有執行條件記錄：$cond"
  eq "MRA_RULE_TOKEN_BUDGET 的值被記錄下來" "1234" "$(jq -r '.token_budget' "$cond")"
}

test_default_token_budget_is_library_default_when_unset() {
  reset_stub_logs
  MRA_BACKTEST_SCRIPT="$STUB/backtest" MRA_RULE_PERSONA_DIR="$TMP" \
    bash "$S" --rules "$FIX/rules" --label budget-default >/dev/null 2>&1
  local cond="$MRA_BENCHMARK_DIR/runs/budget-default/rule-inject-conditions.json"
  eq "沒覆寫時預算記錄成 lib 的預設值" "$RULE_INJECT_DEFAULT_TOKEN_BUDGET" \
    "$(jq -r '.token_budget' "$cond")"
}

# 畸形輸入：--token-budget 給非數字。不該讓整支腳本崩潰——rule_render_block
# 本身的容錯（印警告、退回預設值）要能透過這裡繼續生效，診斷也不能被吞掉。
test_invalid_token_budget_falls_back_without_crashing() {
  reset_stub_logs
  local out rc
  out="$(MRA_BACKTEST_SCRIPT="$STUB/backtest" MRA_RULE_PERSONA_DIR="$TMP" \
    bash "$S" --rules "$FIX/rules" --label budget-bad --token-budget abc 2>&1)"; rc=$?
  [ "$rc" -eq 0 ] && ok "非數字預算不會讓腳本整個失敗" || fail "不該因為非數字預算而失敗：rc=$rc"
  has "印出 rule_render_block 自己的畸形預算診斷" "$out" "RULE_BLOCK_BUDGET_INVALID"
}

# ---------------------------------------------------------------------------
# 「4/5 個 persona」訊息與執行條件記錄
# ---------------------------------------------------------------------------

# 不覆蓋 persona 來源：這支腳本本來就一律用真正的 agents/personas/，剛好
# 讓這個測試同時驗證了「已知事實」本身——test-architect.md 沒有 FOCUS。
test_prints_injection_ratio_with_skip_reason() {
  reset_stub_logs
  local out
  out="$(MRA_BACKTEST_SCRIPT="$STUB/backtest" MRA_RULE_PERSONA_DIR="$TMP" \
    bash "$S" --rules "$FIX/rules" --label ratio-test 2>&1)"
  has "印出注入比例 4/5" "$out" "注入 4/5 個 persona"
  has "點名 test-architect 因為沒有 FOCUS 被跳過" "$out" "test-architect 無 FOCUS 錨點故跳過"
}

test_condition_record_captures_persona_injection_counts() {
  local cond="$MRA_BENCHMARK_DIR/runs/ratio-test/rule-inject-conditions.json"
  [ -f "$cond" ] && ok "執行條件記錄產生了" || fail "沒有執行條件記錄：$cond"
  eq "persona_total 記成 5" "5" "$(jq -r '.persona_total' "$cond")"
  eq "persona_injected 記成 4" "4" "$(jq -r '.persona_injected' "$cond")"
  eq "persona_skipped 記成 1" "1" "$(jq -r '.persona_skipped' "$cond")"
  eq "persona_skipped_names 記錄了 test-architect" \
    "test-architect" "$(jq -r '.persona_skipped_names[0]' "$cond")"
  eq "label 有記進去" "ratio-test" "$(jq -r '.label' "$cond")"
  eq "tolerance 有記進去" "5" "$(jq -r '.tolerance' "$cond")"
}

# ---------------------------------------------------------------------------
# 靜態檢查：這個專案已經為「丟掉診斷」付過四次代價，鎖住
# scripts/run-rule-backtest.sh 不會出現丟棄 stderr 的模式。
# ---------------------------------------------------------------------------
test_script_never_discards_stderr_with_dev_null() {
  lacks "scripts/run-rule-backtest.sh 沒有 2>/dev/null" \
    "$(cat "$MRA_DIR/scripts/run-rule-backtest.sh")" "2>/dev/null"
}

test_injects_before_running_backtest
test_points_persona_dir_at_injected_copy
test_passes_persona_turns_20
test_passes_review_mode_personas
test_defaults_backtest_cmd_to_adapter_when_unset
test_tolerance_is_passed_through
test_default_tolerance_is_5_when_not_given
test_label_is_passed_through
test_refuses_when_rules_dir_empty
test_refuses_when_rules_dir_has_no_md_files
test_refuses_when_rules_path_is_a_file
test_validates_rules_before_running
test_partial_invalid_rules_reports_correct_count_and_blocks
test_missing_rules_and_label_rejected
test_empty_label_is_treated_as_missing
test_flag_missing_value_rejected_not_crashed
test_unknown_flag_rejected
test_token_budget_flag_overrides_and_is_forwarded
test_token_budget_env_var_sets_default_when_no_flag
test_default_token_budget_is_library_default_when_unset
test_invalid_token_budget_falls_back_without_crashing
test_prints_injection_ratio_with_skip_reason
test_condition_record_captures_persona_injection_counts
test_script_never_discards_stderr_with_dev_null

echo "---"; echo "Passed: $pass"; echo "Failed: $errors"
exit $((errors > 0 ? 1 : 0))
