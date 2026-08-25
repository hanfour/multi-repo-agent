#!/usr/bin/env bash
# lib/review-debate-agents.sh：run_synthesize 的 --max-turns 該吃哪個 env。
#
# 背景：run_synthesize 被兩條路徑共用：debate 路徑餵它 2 份 agent 結果，
# personas 路徑餵它 5 份，輸入量是 debate 的 2.5 倍，findings 更多、要寫的
# JSON 更長。舊版寫死 --max-turns 3，是只驗過 debate 路徑(2 份輸入)的經驗
# 值；personas 下實測會撞到這個上限，讓 claude_invoke 回非 0、整個
# `mra review` 指令失敗(acme/rails-app-1#4832，跟先前「synthesize 產出不合法
# JSON」那種安靜失敗是兩回事：這次是真的沒寫完)。
#
# 改成 --max-turns "${MRA_REVIEW_SYNTH_MAX_TURNS:-8}"：不沿用 3(只驗過
# debate 的經驗值)，也不直接跳到跟其他 agent 一樣的
# MRA_REVIEW_AGENT_MAX_TURNS(預設 20，synthesize 不做程式碼探索，只做彙整
# 去重，不需要那麼寬的預算，放太寬只會讓真正卡住的情況更晚被發現)。8 是
# persona 本身的預設輪數(MRA_REVIEW_PERSONA_MAX_TURNS，見
# lib/review-personas.sh)，同一個量級，比 3 有足夠餘裕。
#
# 這支測試直接呼叫 run_synthesize(不透過 review_project，是既有測試檔
# 說的「最小函式層測試」：run_synthesize 對 _project_dir／_mra_dir 這兩個
# 參數只綁定、從不使用，不需要真的建一個專案目錄)，覆寫 claude_invoke
# 記錄實際收到的 argv，逐一比對 --max-turns 後面接的那個值。
set -uo pipefail

MRA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

errors=0; pass=0
ok()   { echo "PASS: $1"; pass=$((pass+1)); }
fail() { echo "FAIL: $1"; errors=$((errors+1)); }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/review-synth-max-turns-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

export MRA_CONFIG="$TMP/config.json"
printf '%s' '{"configVersion":2}' > "$MRA_CONFIG"
# _review_without_github_credentials 的憑證檢查(lib/review-provider.sh 的
# _review_provision_claude_credential)：不用真的 credential，
# ANTHROPIC_API_KEY 有值就直接放行，不會去碰真正的 ~/.claude 目錄
# (那個函式本來就先把 HOME 換到一個新建的暫存目錄才檢查)。
export ANTHROPIC_API_KEY="test-only-dummy-key-not-a-real-secret"

eval "$(sed -n '/^MRA_LIBS=(/,/^)/p' "$MRA_DIR/bin/mra.sh")"
for lib in "${MRA_LIBS[@]}"; do
  # shellcheck source=/dev/null
  source "$MRA_DIR/lib/${lib}.sh"
done

ARGS_FILE="$TMP/claude-invoke-args"
# 覆寫真的會呼叫模型的函式：逐行記錄收到的 argv(prompt 本身有內嵌換行，
# 但 printf 每個 %s 對應一個參數，prompt 之後的旗標仍然各自獨立成行)，
# 回傳一份最小的合法 JSON，不連網路、不用真的 credential。
claude_invoke() {
  printf '%s\n' "$@" > "$ARGS_FILE"
  printf '%s' '{"status":"CHANGES_REQUESTED","summary":"stub","comments":[]}'
  return 0
}

# --max-turns 後面緊接著的下一行就是它的值。
max_turns_arg() {
  awk '/^--max-turns$/{getline; print; exit}' "$ARGS_FILE"
}

call_synth() {
  run_synthesize "proj" "$TMP/project" "DIFF" "changed.txt" \
    "findings A" "findings B" "" "false" "" "sonnet" "" "$MRA_DIR" \
    >"$TMP/out" 2>"$TMP/err"
}

# --- 案例 1：未設 MRA_REVIEW_SYNTH_MAX_TURNS 時，預設是 8 -------------------
unset MRA_REVIEW_SYNTH_MAX_TURNS
rm -f "$ARGS_FILE"
call_synth
mt1="$(max_turns_arg)"
if [[ "$mt1" == "8" ]]; then
  ok "未設 env 時，synthesize 收到的是 --max-turns 8"
else
  fail "未設 env 時，synthesize 應該收到 --max-turns 8，實際是 [$mt1]"
fi

# --- 案例 2：設了 MRA_REVIEW_SYNTH_MAX_TURNS 時用設定值 ----------------------
export MRA_REVIEW_SYNTH_MAX_TURNS=15
rm -f "$ARGS_FILE"
call_synth
mt2="$(max_turns_arg)"
if [[ "$mt2" == "15" ]]; then
  ok "設了 MRA_REVIEW_SYNTH_MAX_TURNS=15 時，synthesize 用設定值(收到 --max-turns 15)"
else
  fail "設了 MRA_REVIEW_SYNTH_MAX_TURNS=15 時，synthesize 應該收到 --max-turns 15，實際是 [$mt2]"
fi
unset MRA_REVIEW_SYNTH_MAX_TURNS

echo "---"; echo "Passed: $pass"; echo "Failed: $errors"
exit $((errors > 0 ? 1 : 0))
