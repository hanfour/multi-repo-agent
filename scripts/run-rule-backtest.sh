#!/usr/bin/env bash
# 帶規則跑回測：先驗規則 → 注入 persona → 指向注入後的目錄 → 呼叫階段二的
# scripts/run-backtest.sh。
#
# 先驗規則再跑：跑完才發現規則格式壞掉等於白燒幾小時。這是階段二學到的
# 「失敗要早、要響」的同一條原則——見下面的 NO_RULES／RULES_INVALID 區塊，
# 任何一個規則檔沒通過 rule_validate 就整批擋下來，絕對不呼叫 backtest。
#
# 執行條件必須與階段二的基準線 C 完全一致（見
# docs/superpowers/notes/2026-backtest-baseline.md）：MRA_BACKTEST_REVIEW_MODE
# =personas、MRA_REVIEW_PERSONA_MAX_TURNS=20（刻意偏離預設 8，預設下五成 PR
# 跑不完）、provider claude model sonnet（由 adapter 的衍生 config 決定）、
# worktree 隔離、三點 range。只有規則不同——任何其他差異都會讓比較出來的
# 差異可能來自條件而不是規則。這幾個值因此寫死在這裡，不開放成參數。
#
# MRA_PERSONAS_DIR 是 review 流程真正的覆蓋點（lib/personas.sh 的
# _personas_dir()，Task 7 加的）。分層之後由 run-backtest.sh 逐 PR 設定它，
# 這支腳本交出去的是 MRA_PERSONAS_ROOT：一個底下每層各一份 persona 副本的
# 根目錄，不是原本的 agents/personas。
#
# 分層注入：回測涵蓋 rails／react／nestjs 三種 repo。persona 目錄是 review 流程
# 唯一的載入點（lib/personas.sh 的 _personas_dir()），一次只能指向一個目錄，所以
# 這裡對每一層各展開一份完整的 persona 副本（personas-<label>/<層>/），再由
# run-backtest.sh 逐 PR 依 repo 所屬層挑要載入哪一份（見那邊的 MRA_PERSONAS_ROOT）。
#
# 這是階段四補上的。在此之前只注入 common 層，rails／react／vue／nestjs 四層的
# 規則從未進過任何一次 review 的 prompt。
#
# agents/personas/test-architect.md 沒有 FOCUS: 錨點（它用「KENT BECK 11
# PRINCIPLES:」取代），注入時會原樣複製、不注入規則——這代表每一層的五個
# persona 都只有四個真的拿到規則。這是既有事實，不是這裡要修的 bug：改
# test-architect.md 讓它能被注入的話，會改變階段二基準線 C 的條件，兩者就
# 不可比了。這裡只把這件事在執行時明確印出來，並寫進執行條件記錄。
set -uo pipefail

MRA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$MRA_DIR/lib/corpus-targets.sh"
source "$MRA_DIR/lib/rule-schema.sh"
source "$MRA_DIR/lib/rule-inject.sh"

RULES=""
LABEL=""
TOL="${MRA_RULE_BACKTEST_TOL:-5}"
# 注入上限是 token 預算，不是條數：見 lib/rule-inject.sh 檔頭的說明（A 路線
# 跟 B 路線在同一個「取前 N 條」上限下注入量差了 2.9 倍，改成 token 預算才能
# 公平比較）。空字串表示「不覆寫」，讓 rule_inject_all 用它自己的預設值
# （$RULE_INJECT_DEFAULT_TOKEN_BUDGET，目前是 5000）。
BUDGET="${MRA_RULE_TOKEN_BUDGET:-}"
RECOMPUTE_FLAG=""

while [ $# -gt 0 ]; do
  case "$1" in
    --rules)
      [ $# -ge 2 ] || { echo "用法：--rules 需要接一個目錄" >&2; exit 1; }
      RULES="$2"; shift 2 ;;
    --label)
      [ $# -ge 2 ] || { echo "用法：--label 需要接一個名稱" >&2; exit 1; }
      LABEL="$2"; shift 2 ;;
    --tolerance)
      [ $# -ge 2 ] || { echo "用法：--tolerance 需要接一個值" >&2; exit 1; }
      TOL="$2"; shift 2 ;;
    --token-budget)
      [ $# -ge 2 ] || { echo "用法：--token-budget 需要接一個值" >&2; exit 1; }
      BUDGET="$2"; shift 2 ;;
    --recompute)
      # 換容差再算一次時用。原樣傳給 run-backtest.sh，見那邊的說明：不加這個
      # 旗標的話，重算會連帶重跑失敗的 PR 並覆寫它們的 .err。
      RECOMPUTE_FLAG="--recompute"; shift ;;
    -h|--help)
      echo "用法：run-rule-backtest.sh --rules <目錄> --label <名稱> [--tolerance N] [--token-budget N] [--recompute]"
      echo "  --recompute：只重算指標，不跑 review、不覆寫失敗 PR 的 .err"
      exit 0 ;;
    *)
      echo "用法：不認得的旗標 $1" >&2
      exit 1 ;;
  esac
done
[ -n "$RULES" ] && [ -n "$LABEL" ] || { echo "缺 --rules 或 --label" >&2; exit 1; }

# --tolerance 最終會被 --argjson 塞進下面的執行條件 JSON（tolerance 欄位），
# 也會原樣傳給 run-backtest.sh。不合法就用自己的 token 擋下來，不要讓使用者
# 在規則驗證都通過、注入都做完之後，才在寫執行條件記錄那一步看到一句跟輸入
# 完全無關的 jq parse error。
#
# 檢查的是「非負數」，不是「合法 JSON」。只驗 `jq --argjson t "$TOL" 'true'`
# 的話，`null`、`-3`、`[]`、`{}` 全部會過，而 null 與負值的後果是每一條
# expected 都不命中、漏抓率變成完美的 1.0（jq 的型別排序裡 null 小於任何
# 數字，`距離 <= null` 恆為 false）。那是一個沒有錯誤訊息的假結果。
if ! jq -n --argjson t "$TOL" -e '($t | type) == "number" and $t >= 0' >/dev/null 2>&1; then
  echo "TOLERANCE_INVALID：--tolerance 的值「${TOL}」不是非負數" >&2
  exit 1
fi

# --- 驗規則：跑完才發現規則格式壞掉等於白燒幾小時 --------------------------
if [ ! -d "$RULES" ]; then
  echo "NO_RULES：${RULES} 不是目錄" >&2
  exit 1
fi

# 用陣列蒐集規則檔而不是 `ls ... | wc -l`：後者要嘛得把 ls 的 stderr 導去
# /dev/null 吞掉它對不存在目錄的錯誤訊息（這個專案已經為丟掉診斷這個模式
# 付過四次代價），要嘛在目錄存在但是空的時候把「空規則集」跟「ls 本身失敗」
# 混在一起判斷。這裡先用 [ -d ] 單獨擋掉目錄不存在的情況，下面的迴圈只需要
# 處理「glob 沒有展開」這一種空結果。
rule_files=()
for f in "$RULES"/*.md; do
  [ -e "$f" ] || continue
  rule_files+=("$f")
done
[ "${#rule_files[@]}" -gt 0 ] || {
  echo "NO_RULES：${RULES} 底下沒有規則檔" >&2
  exit 1
}
n_rules="${#rule_files[@]}"

# rule_validate 自己會把每個問題印到 stderr（見 lib/rule-schema.sh），這裡
# 只負責計數、決定要不要整批擋下來——不重複印一次規則本身的內容。
bad=0
for f in "${rule_files[@]}"; do
  rule_validate "$f" || bad=$((bad + 1))
done
[ "$bad" -eq 0 ] || {
  echo "RULES_INVALID：${bad}/${n_rules} 個規則檔沒通過驗證，先修好再跑（見上方訊息）" >&2
  exit 1
}

# --- 注入 persona：每一層各一份 ---------------------------------------------
# 注入結果的根目錄，底下每層一個子目錄（personas-<label>/rails/、
# .../react/ ...）。run-backtest.sh 收到的是這個根目錄，逐 PR 依 repo 所屬層
# 挑要載入哪一份。
INJECTED="${MRA_RULE_PERSONA_DIR:-${TMPDIR:-/tmp}}/personas-${LABEL}"

# 層清單用 corpus_layers()，與語料取材、規則萃取用的是同一份定義。在這裡另外
# 寫死一份清單的話，之後新增一層時兩邊會漂移，而漂移的後果是那一層的規則
# 靜默地不參與回測。
LAYERS="$(corpus_layers | tr '\n' ' ')"

# rule_inject_layers 用 stderr 回報兩種完全不同的事：真正的硬錯誤（persona
# 來源目錄不存在、mv 失敗等），以及正常但值得知道的資訊（哪個 persona 因為
# 沒有 FOCUS 被原樣複製）。兩種都不能被丟棄，但後者要被解析出「4/5」這種
# 摘要，所以先落到暫存檔，再原樣轉印到真正的 stderr、同時解析。
inject_log="$(mktemp "${TMPDIR:-/tmp}/rule-backtest-inject.XXXXXX")" || {
  echo "INJECT_FAILED：無法建立暫存記錄檔" >&2
  exit 1
}

# 第四個參數（persona 來源目錄）給空字串表示用預設的 agents/personas，第五個
# 是 token 預算、空字串表示不覆寫——兩個都能無條件傳，不像 rule_inject_all
# 需要為「有沒有覆寫預算」分成兩種呼叫形式。
layer_report="$(rule_inject_layers "$RULES" "$INJECTED" "$LAYERS" "" "$BUDGET" 2>"$inject_log")"
inject_rc=$?

[ -s "$inject_log" ] && cat "$inject_log" >&2

if [ "$inject_rc" -ne 0 ] || [ -z "$layer_report" ]; then
  echo "INJECT_FAILED：規則注入失敗（見上方診斷）" >&2
  rm -f "$inject_log"
  exit 1
fi

# 每層的 persona 總數與跳過數必然相同（每層都注入同一份 agents/personas），
# 取第一行即可；逐層真正不同的是「這一層有幾條規則進了 prompt」。
n_total="$(printf '%s\n' "$layer_report" | head -n 1 | cut -f2)"
n_skipped="$(printf '%s\n' "$layer_report" | head -n 1 | cut -f3)"
n_layers="$(printf '%s\n' "$layer_report" | grep -c . || true)"

# 用陣列＋逐一 append 組「、」分隔的清單，不用 `tr '、' ...` 或
# `paste -sd '、' -`：兩者都要處理一個多位元組 UTF-8 分隔字元，行為依賴呼叫
# 環境的 locale——這支腳本沒有像 lib/rule-inject.sh 的 _rule_char_count 那樣
# 釘死 LC_ALL，不該假設呼叫端一定是 UTF-8 aware 的 locale。純 bash 字串串接
# 不需要「認得」UTF-8 才能正確處理位元組序列，不受 locale 影響。
#
# sort -u：分層之後同一個沒有 FOCUS 的 persona 會在每一層各被跳過一次，
# 訊息因此重複五遍。這裡要的是「哪些 persona 沒拿到規則」，不是「跳過事件
# 發生幾次」。
skipped_names=""
skipped_arr=()
if [ "$n_skipped" -gt 0 ]; then
  while IFS= read -r p; do
    skipped_arr+=("$(basename "$p" .md)")
  done < <(grep '^RULE_INJECT_SKIPPED' "$inject_log" | cut -f2 | LC_ALL=C sort -u)
  for name in "${skipped_arr[@]}"; do
    if [ -z "$skipped_names" ]; then
      skipped_names="$name"
    else
      skipped_names="${skipped_names}、${name}"
    fi
  done
fi
rm -f "$inject_log"

n_injected=$((n_total - n_skipped))
if [ "$n_skipped" -gt 0 ]; then
  echo "每層注入 ${n_injected}/${n_total} 個 persona，共 ${n_layers} 層，${skipped_names} 無 FOCUS 錨點故跳過"
else
  echo "每層注入 ${n_injected}/${n_total} 個 persona，共 ${n_layers} 層"
fi

# 規則檔數與「實際進 prompt 的條數」是兩個不同的數字，要分開印：一份 140 個
# 檔案的規則集，每層看得到的只有自己這層加 common，token 預算還會再截斷
# 一次，實際進 prompt 的通常是個位數。只印前者會讓人以為整份規則集都被
# 測過了。
echo "規則檔 ${n_rules} 個，各層實際進 prompt 的條數："
printf '%s\n' "$layer_report" | while IFS=$'\t' read -r l _t _s r; do
  [ -n "$l" ] || continue
  printf '  %-8s %s 條\n' "$l" "$r"
done
echo "注入後的 persona 在 ${INJECTED}/<層>/"

# $BUDGET 可能是使用者打錯的畸形值（非數字、0、負數）——rule_render_block
# 自己會印 RULE_BLOCK_BUDGET_INVALID 警告並優雅退回預設值，這裡不重複那個
# 判斷去改變行為，但寫進執行條件記錄的必須是「實際生效」的數字，不能原樣
# 塞一個非數字字串進去，否則下面 jq --argjson 會因為值不是合法 JSON 數字
# 而整段失敗，讓一個只該印警告、優雅降級的畸形輸入意外變成硬錯誤。判斷式
# 刻意跟 rule_render_block 的驗證用同一個 case pattern：兩邊要認定「同一個
# 值有沒有效」是同一件事，不能各自漂移出不同的答案。
case "$BUDGET" in
  ''|*[!0-9]*|0) EFFECTIVE_BUDGET="$RULE_INJECT_DEFAULT_TOKEN_BUDGET" ;;
  *) EFFECTIVE_BUDGET="$BUDGET" ;;
esac

# --- 執行條件記錄：跟 summary.json 一樣走 tmp→mv，兩邊退出碼都要驗 ---------
# 這份記錄跟 run-backtest.sh／adapter 寫的 run-conditions.json（provider／
# model／turn 數等）是互補關係，不是重複：那份記的是「review 本身跑在什麼
# 條件下」，這份記的是「規則怎麼被注入的」——哪套規則、幾條、token 預算、
# 幾個 persona 真的拿到規則、哪些沒有。兩份合起來才是一輪回測完整的執行
# 條件，任何一份漏記，階段四要重建這輪的條件時就會少一塊。
BENCH_DIR="${MRA_BENCHMARK_DIR:-$HOME/.cache/mra-review-benchmark}"
COND_DIR="$BENCH_DIR/runs/$LABEL"
if ! mkdir -p "$COND_DIR"; then
  echo "COND_DIR_MKDIR_FAILED：無法建立 ${COND_DIR}" >&2
  exit 1
fi
COND_FILE="$COND_DIR/rule-inject-conditions.json"
COND_TMP="${COND_FILE}.tmp"

# 直接從 $skipped_arr（陣列，元素本身沒有分隔字元問題）組 JSON 陣列，不是
# 反過來切開給人看的 $skipped_names（那個字串用「、」分隔，重新切開一樣會
# 踩到上面提過的 locale 依賴問題）。
#
# 陣列是空的時候要特判成 '[]'，不能無條件丟給
# `printf '%s\n' "${skipped_arr[@]}" | jq -R . | jq -s .`：陣列展開成零個
# 參數時，printf 的格式字串仍然會被套用一次（POSIX 對「參數比轉換規格少」
# 的行為是拿空字串／0 補上，不是完全不輸出），所以 `printf '%s\n'`
# 在零個參數下還是會印出一個空行，讓 `jq -R .` 收到一行空字串、`jq -s .`
# 因此組出 `[""]` 而不是 `[]`——這裡的正確答案應該是零個 persona 被跳過，
# 混進一個假的空字串元素會讓 persona_skipped_names 的長度跟
# persona_skipped 的數字對不起來。
if [ "${#skipped_arr[@]}" -gt 0 ]; then
  skipped_json="$(printf '%s\n' "${skipped_arr[@]}" | jq -R . | jq -s .)"
else
  skipped_json='[]'
fi

# 逐層的注入結果。n_rules（規則檔總數）描述的是輸入，這個陣列描述的才是
# 「實際有多少條規則進了那一層的 prompt」——兩者差距很大（一份 140 個檔案的
# 規則集，每層通常只進得去個位數），只記前者會讓之後重建這輪條件的人以為
# 整份規則集都被測過了。
if ! layers_json="$(printf '%s\n' "$layer_report" | jq -R -s '
      split("\n") | map(select(length > 0) | split("\t") | {
        layer: .[0],
        persona_total: (.[1] | tonumber),
        persona_skipped: (.[2] | tonumber),
        rules_injected: (.[3] | tonumber)
      })')"; then
  echo "COND_LAYERS_FAILED：無法把逐層注入結果轉成 JSON，${COND_FILE} 未變動" >&2
  exit 1
fi

# --recompute 且已經有一份記錄時就保留它，不覆寫。這份記錄描述的是「summary
# 裡的數字是在什麼規則集下跑出來的」；重算容差時 review 沒有重跑，規則集卻
# 可能已經改了，覆寫等於把記錄跟它描述的對象拆開 —— 檔案裡是新規則集、數字
# 來自舊 review，而且從檔案本身看不出這件事。
#
# 沒有既有記錄時照樣寫：那表示這個 label 是第一次跑，或上一輪的記錄遺失了，
# 兩種情況下寫一份都比留空好。
if [ -n "$RECOMPUTE_FLAG" ] && [ -f "$COND_FILE" ]; then
  echo "RECOMPUTE_KEEP_CONDITIONS：保留既有的 ${COND_FILE}（--recompute 不重跑 review，覆寫會讓記錄與數字對不起來）" >&2
else
  if ! jq -n \
    --arg label "$LABEL" \
    --arg rules_dir "$RULES" \
    --argjson n_rules "$n_rules" \
    --arg persona_dir "$INJECTED" \
    --argjson persona_total "$n_total" \
    --argjson persona_injected "$n_injected" \
    --argjson persona_skipped "$n_skipped" \
    --argjson persona_skipped_names "$skipped_json" \
    --argjson token_budget "$EFFECTIVE_BUDGET" \
    --argjson tolerance "$TOL" \
    --argjson layers "$layers_json" \
    '{label: $label, rules_dir: $rules_dir, n_rules: $n_rules,
      persona_dir: $persona_dir, persona_total: $persona_total,
      persona_injected: $persona_injected, persona_skipped: $persona_skipped,
      persona_skipped_names: $persona_skipped_names,
      layers: $layers,
      token_budget: $token_budget, tolerance: $tolerance}' > "$COND_TMP"; then
    echo "COND_WRITE_FAILED：寫入執行條件記錄失敗，${COND_FILE} 未變動" >&2
    rm -f "$COND_TMP"
    exit 1
  fi
  if ! mv "$COND_TMP" "$COND_FILE"; then
    echo "COND_PROMOTE_FAILED：搬移執行條件記錄到 ${COND_FILE} 失敗" >&2
    rm -f "$COND_TMP"
    exit 1
  fi
fi

# --- 呼叫階段二的 run-backtest.sh -------------------------------------------
# MRA_BACKTEST_CMD 呼叫端已經指定就用呼叫端的（測試會用這個點指向 stub，
# 不需要真的透過 backtest-review-adapter.sh），沒指定才預設用 adapter。
BACKTEST="${MRA_BACKTEST_SCRIPT:-$MRA_DIR/scripts/run-backtest.sh}"

MRA_BACKTEST_CMD="${MRA_BACKTEST_CMD:-$MRA_DIR/scripts/backtest-review-adapter.sh}" \
MRA_BACKTEST_REVIEW_MODE=personas \
MRA_REVIEW_PERSONA_MAX_TURNS=20 \
MRA_PERSONAS_ROOT="$INJECTED" \
  bash "$BACKTEST" --label "$LABEL" --tolerance "$TOL" $RECOMPUTE_FLAG
backtest_rc=$?
exit "$backtest_rc"
