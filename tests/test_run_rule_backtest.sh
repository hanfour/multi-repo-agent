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
#      「注入 N-1/N 個 persona」，並且寫進執行條件記錄裡，不是只印在
#      stdout 上跑完就沒了。
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

# 內建 persona 的數量與其中會被注入的數量，從目錄數出來而不是寫死；同上，
# 寫死會讓每個新 persona 都弄紅一支不相干的測試。跳過的仍然硬驗成 1 個且
# 名字是 test-architect（它用「KENT BECK 11 PRINCIPLES:」取代 FOCUS），
# 所以「注入幾個」這件事沒有因為改成算出來就沒人守。
PERSONA_TOTAL="$(find "$MRA_DIR/agents/personas" -maxdepth 1 -name '*.md' \
  ! -name 'README.md' | wc -l | tr -d ' ')"
PERSONA_INJECTED=$((PERSONA_TOTAL - 1))

errors=0; pass=0
ok()   { echo "PASS: $1"; pass=$((pass+1)); }
fail() { echo "FAIL: $1"; errors=$((errors+1)); }
eq()   { if [[ "$2" == "$3" ]]; then ok "$1"; else fail "$1 — expected [$2] got [$3]"; fi; }
has()  { case "$2" in *"$3"*) ok "$1" ;; *) fail "$1 — 沒看到「$3」：$2" ;; esac; }
# 空的 haystack 直接算失敗：`lacks "..." "$(cat 不存在的檔案)" "needle"` 對
# 空字串一定通過，而空字串幾乎總是「東西沒讀到」而不是「讀到了但不含它」。
# 實測過一次：同一個函式裡配對的 has FAIL 而 lacks PASS，兩個斷言對同一份
# 資料給出矛盾的結果。真的要斷言某處本來就該是空的，用 eq "" "$x" 講清楚。
lacks(){
  if [ -z "$2" ]; then
    fail "$1 — 被檢查的內容是空的（多半是東西沒讀到，不是真的不含「$3」）"
    return
  fi
  case "$2" in *"$3"*) fail "$1 — 不該看到「$3」：$2" ;; *) ok "$1" ;; esac
}

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
  printf 'MRA_PERSONAS_ROOT=%s\n' "\${MRA_PERSONAS_ROOT:-<unset>}"
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
# 出處數可控的規則檔，給 token 預算覆寫測試用。固定 layer=common 是因為
# common 層對每一層都可見，任選一層的注入結果都看得到它；分層本身另有
# 一組測試（見「分層注入」那一節），不靠這個 helper。
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
  local injected="$TMP/personas-rules-test/common/security-auditor.md"
  [ -f "$injected" ] && ok "產出了注入後的 persona" || fail "沒有注入後的 persona"
  has "注入後含 RULESET" "$(cat "$injected")" "BEGIN RULESET"
}

test_points_persona_root_at_injected_copy() {
  local env_log; env_log="$(cat "$STUB/env.log")"
  has "MRA_PERSONAS_ROOT 指向注入後的根目錄" "$env_log" "MRA_PERSONAS_ROOT=$TMP/personas-rules-test"
  lacks "不是原本的 agents/personas" "$env_log" "$MRA_DIR/agents/personas"
  # 逐 PR 決定要載入哪一層是 run-backtest.sh 的事。這支腳本自己先釘死一個
  # MRA_PERSONAS_DIR 的話，每個 PR 都會讀到同一層，分層等於沒做——而且外觀
  # 上完全正常，summary 照樣跑得出來。
  has "不自己釘死 MRA_PERSONAS_DIR" "$env_log" "MRA_PERSONAS_DIR=<unset>"
}

# ---------------------------------------------------------------------------
# 分層注入：每層各一份 persona 副本
# ---------------------------------------------------------------------------

test_injects_one_persona_dir_per_layer() {
  write_backtest_stub
  reset_stub_logs
  MRA_BACKTEST_SCRIPT="$STUB/backtest" MRA_RULE_PERSONA_DIR="$TMP" \
    bash "$S" --rules "$FIX/rules" --label layered >/dev/null 2>&1
  local l
  for l in $(corpus_layers); do
    if [ -f "$TMP/personas-layered/$l/security-auditor.md" ]; then
      ok "$l 層有自己的 persona 副本"
    else
      fail "$l 層沒有 persona 副本：$TMP/personas-layered/$l/"
    fi
  done
}

# 這是分層注入要解決的問題本身：在此之前只注入 common 層，nestjs 與 react
# 層的規則從來不會出現在任何一次 review 的 prompt 裡。兩個方向都要驗——
# 只驗「nestjs 層有 nestjs 規則」的話，一個把所有層的規則全部塞進每一層的
# 退化實作也會通過，而那等於沒有分層。
test_layer_rules_reach_the_matching_layer_only() {
  local nest react
  nest="$(cat "$TMP/personas-layered/nestjs/security-auditor.md")"
  react="$(cat "$TMP/personas-layered/react/security-auditor.md")"
  has "nestjs 層的 persona 含 nestjs 規則" "$nest" "nestjs-injectable-scope"
  lacks "nestjs 層的 persona 不含 react 規則" "$nest" "react-effect-cleanup"
  has "react 層的 persona 含 react 規則" "$react" "react-effect-cleanup"
  lacks "react 層的 persona 不含 nestjs 規則" "$react" "nestjs-injectable-scope"
  has "每層都仍然含 common 層規則" "$nest" "common-debug-artifact"
}

# 執行條件記錄要能回答「這一層實際有幾條規則進了 prompt」。規則檔總數
# （n_rules）回答不了這件事：每層看得到的只有自己這層加 common，token 預算
# 還會再截斷一次。只記檔案總數的話，之後重建這輪條件的人會以為整份規則集
# 都被測過了。
test_condition_record_captures_per_layer_rule_counts() {
  local cond="$MRA_BENCHMARK_DIR/runs/layered/rule-inject-conditions.json"
  [ -f "$cond" ] && ok "分層執行條件記錄產生了" || fail "沒有執行條件記錄：$cond"
  eq "layers 陣列涵蓋每一層" "$(corpus_layers | grep -c .)" \
    "$(jq -r '.layers | length' "$cond")"
  # fixture 是 common、nestjs、react 各一條。nestjs 層看得到自己那條加
  # common，所以是 2；vue 層沒有自己的規則，只剩 common 那 1 條。
  eq "nestjs 層記錄注入 2 條" "2" \
    "$(jq -r '.layers[] | select(.layer == "nestjs") | .rules_injected' "$cond")"
  eq "vue 層只有 common 那 1 條" "1" \
    "$(jq -r '.layers[] | select(.layer == "vue") | .rules_injected' "$cond")"
  eq "每層的 persona 總數與內建 persona 檔數一致" "$PERSONA_TOTAL" \
    "$(jq -r '.layers[] | select(.layer == "rails") | .persona_total' "$cond")"
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
  local body; body="$(cat "$TMP/personas-budget-cli/common/security-auditor.md")"
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
  has "印出注入比例" "$out" "注入 $PERSONA_INJECTED/$PERSONA_TOTAL 個 persona"
  has "點名 test-architect 因為沒有 FOCUS 被跳過" "$out" "test-architect 無 FOCUS 錨點故跳過"
}

test_condition_record_captures_persona_injection_counts() {
  local cond="$MRA_BENCHMARK_DIR/runs/ratio-test/rule-inject-conditions.json"
  [ -f "$cond" ] && ok "執行條件記錄產生了" || fail "沒有執行條件記錄：$cond"
  eq "persona_total 是內建 persona 檔數" "$PERSONA_TOTAL" "$(jq -r '.persona_total' "$cond")"
  eq "persona_injected 是總數扣掉沒有 FOCUS 的那一個" "$PERSONA_INJECTED" "$(jq -r '.persona_injected' "$cond")"
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
test_points_persona_root_at_injected_copy
test_injects_one_persona_dir_per_layer
test_layer_rules_reach_the_matching_layer_only
test_condition_record_captures_per_layer_rule_counts
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
# --recompute 要原樣傳給 run-backtest.sh。沒傳到的話，換容差再算一次會連帶
# 重跑失敗的 PR 並覆寫它們的 .err（見 scripts/run-backtest.sh 的說明）。
# 傳遞用的是未加引號的 $RECOMPUTE_FLAG，空值時必須完全不出現在 argv 裡，
# 不能變成一個空字串參數 —— run-backtest.sh 對不認得的參數是直接 exit 1。
test_recompute_flag_is_forwarded() {
  reset_stub_logs
  MRA_BACKTEST_SCRIPT="$STUB/backtest" MRA_RULE_PERSONA_DIR="$TMP" \
    bash "$S" --rules "$FIX/rules" --label rc-fwd --recompute >/dev/null 2>&1
  has "--recompute 有傳給 run-backtest.sh" "$(cat "$STUB/argv.log" 2>/dev/null)" "--recompute"
}

test_no_recompute_flag_when_not_given() {
  reset_stub_logs
  MRA_BACKTEST_SCRIPT="$STUB/backtest" MRA_RULE_PERSONA_DIR="$TMP" \
    bash "$S" --rules "$FIX/rules" --label rc-off >/dev/null 2>&1
  local argv; argv="$(cat "$STUB/argv.log" 2>/dev/null)"
  lacks "沒給 --recompute 時 argv 裡不該出現它" "$argv" "--recompute"
  # 空的 $RECOMPUTE_FLAG 若展開成一個空參數，argv 會多一個空欄位。用 tolerance
  # 後面緊接著就是結尾來釘住這件事。
  case "$argv" in
    *"--tolerance 5") ok "argv 結尾就是 --tolerance 5，沒有多出空參數" ;;
    *) fail "argv 結尾不對，可能多了空參數：[$argv]" ;;
  esac
}

# run-rule-backtest.sh 自己那道容差驗證原本零覆蓋：整段刪掉測試也全綠。
# 驗的是「非負數」不是「合法 JSON」，null 與負值都會讓每一條 expected 都不
# 命中、漏抓率變成完美的 1.0（jq 的型別排序裡 null 小於任何數字）。
test_tolerance_must_be_non_negative_number() {
  local bad out
  for bad in null -3 '[]' '{}' abc '"5"'; do
    reset_stub_logs
    out="$(MRA_BACKTEST_SCRIPT="$STUB/backtest" MRA_RULE_PERSONA_DIR="$TMP" \
      bash "$S" --rules "$FIX/rules" --label tol-bad --tolerance "$bad" 2>&1)"
    has "容差 [$bad] 被 TOLERANCE_INVALID 擋下來" "$out" "TOLERANCE_INVALID"
    # 擋下來的時候不該已經做完規則驗證與注入 —— 那是這道檢查放在最前面的理由
    lacks "容差 [$bad] 擋在注入之前" "$out" "注入 "
  done
}

test_valid_tolerance_not_rejected() {
  local good out
  for good in 0 5 15 2.5; do
    reset_stub_logs
    out="$(MRA_BACKTEST_SCRIPT="$STUB/backtest" MRA_RULE_PERSONA_DIR="$TMP" \
      bash "$S" --rules "$FIX/rules" --label tol-ok --tolerance "$good" 2>&1)"
    lacks "合法容差 [$good] 沒被誤擋" "$out" "TOLERANCE_INVALID"
  done
}

# MRA_RULE_BACKTEST_TOL 是 --tolerance 的環境變數版本，同樣沒被測過。
test_tolerance_env_var_is_used_and_validated() {
  reset_stub_logs
  MRA_RULE_BACKTEST_TOL=15 MRA_BACKTEST_SCRIPT="$STUB/backtest" MRA_RULE_PERSONA_DIR="$TMP" \
    bash "$S" --rules "$FIX/rules" --label tol-env >/dev/null 2>&1
  has "MRA_RULE_BACKTEST_TOL 有傳給 run-backtest.sh" \
    "$(cat "$STUB/argv.log" 2>/dev/null)" "--tolerance 15"

  local out
  out="$(MRA_RULE_BACKTEST_TOL=null MRA_BACKTEST_SCRIPT="$STUB/backtest" MRA_RULE_PERSONA_DIR="$TMP" \
    bash "$S" --rules "$FIX/rules" --label tol-env-bad 2>&1)"
  has "環境變數版本也走同一道驗證" "$out" "TOLERANCE_INVALID"
}

# --recompute 與 --token-budget 併用：兩個旗標都要生效，不能互相吃掉。
test_recompute_and_token_budget_combine() {
  reset_stub_logs
  MRA_BACKTEST_SCRIPT="$STUB/backtest" MRA_RULE_PERSONA_DIR="$TMP" \
    bash "$S" --rules "$FIX/rules" --label combo --token-budget 3000 --recompute >/dev/null 2>&1
  local argv; argv="$(cat "$STUB/argv.log" 2>/dev/null)"
  has "--recompute 有傳下去" "$argv" "--recompute"
  local cond="$MRA_BENCHMARK_DIR/runs/combo/rule-inject-conditions.json"
  if [ -f "$cond" ]; then
    eq "--token-budget 有生效（記進執行條件）" "3000" "$(jq -r '.token_budget' "$cond")"
  else
    fail "沒有產生執行條件記錄：$cond"
  fi
}

# 執行條件記錄描述的是「summary 裡的數字是在什麼規則集下跑出來的」。
# --recompute 不重跑 review，規則集卻可能已經改了，覆寫等於把記錄跟它描述的
# 對象拆開 —— 檔案裡是新規則集、數字來自舊 review，從檔案本身看不出來。
test_recompute_keeps_existing_inject_conditions() {
  local cond="$MRA_BENCHMARK_DIR/runs/keepcond/rule-inject-conditions.json"
  # 第一輪：正常模式，用 fixture 的規則集
  reset_stub_logs
  MRA_BACKTEST_SCRIPT="$STUB/backtest" MRA_RULE_PERSONA_DIR="$TMP" \
    bash "$S" --rules "$FIX/rules" --label keepcond >/dev/null 2>&1
  local n_before; n_before="$(jq -r '.n_rules' "$cond" 2>/dev/null)"

  # 第二輪：--recompute，但指向一個條數不同的規則集
  local other="$TMP/other-rules"
  mkdir -p "$other"
  write_common_rule "$other" keepcond-a 5
  write_common_rule "$other" keepcond-b 4
  local out
  out="$(MRA_BACKTEST_SCRIPT="$STUB/backtest" MRA_RULE_PERSONA_DIR="$TMP" \
    bash "$S" --rules "$other" --label keepcond --recompute 2>&1)"

  has "印出保留既有記錄的訊息" "$out" "RECOMPUTE_KEEP_CONDITIONS"
  eq "執行條件記錄沒有被新規則集覆寫" "$n_before" "$(jq -r '.n_rules' "$cond" 2>/dev/null)"

  # 對照：同一個新規則集在正常模式下要真的覆寫
  MRA_BACKTEST_SCRIPT="$STUB/backtest" MRA_RULE_PERSONA_DIR="$TMP" \
    bash "$S" --rules "$other" --label keepcond >/dev/null 2>&1
  eq "正常模式下記錄有更新成新規則集的條數" "2" "$(jq -r '.n_rules' "$cond" 2>/dev/null)"
}

test_flag_missing_value_rejected_not_crashed
test_unknown_flag_rejected
test_tolerance_must_be_non_negative_number
test_valid_tolerance_not_rejected
test_tolerance_env_var_is_used_and_validated
test_recompute_and_token_budget_combine
test_recompute_keeps_existing_inject_conditions
test_token_budget_flag_overrides_and_is_forwarded
test_token_budget_env_var_sets_default_when_no_flag
test_default_token_budget_is_library_default_when_unset
test_invalid_token_budget_falls_back_without_crashing
test_prints_injection_ratio_with_skip_reason
test_condition_record_captures_persona_injection_counts
test_script_never_discards_stderr_with_dev_null
test_recompute_flag_is_forwarded
test_no_recompute_flag_when_not_given

echo "---"; echo "Passed: $pass"; echo "Failed: $errors"
exit $((errors > 0 ? 1 : 0))
