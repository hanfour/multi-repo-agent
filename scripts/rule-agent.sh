#!/usr/bin/env bash
# scripts/rule-agent.sh — 讀 stdin 的群組 JSON，呼叫 claude 產出 canonical 規則。
# 兩條萃取路線共用這支，差別只在餵進來的 JSON 形狀與 prompt 前綴。
set -uo pipefail
MRA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$MRA_DIR/lib/colors.sh"
source "$MRA_DIR/lib/claude-invoke.sh"
input="$(cat)"
prefix="${MRA_RULE_PROMPT_PREFIX:-這是一組主題相近的 code review 意見。}"

prompt="${prefix}

請產出一條 canonical 規則，格式如下（frontmatter 與五個章節都必填）。輸出必須
「直接」以 --- 開頭，前面不要加任何說明、標題、前言或你的判斷過程；結尾也不要
加額外的補充文字或簽名——只要 frontmatter 和五個章節，其他一律不要輸出。下面
「意見」欄位已經是你需要的全部素材，不需要、也不要讀取或搜尋任何檔案：

---
id: <層>-<用連字號的簡短英文描述>
layer: <common|nestjs|rails|react|vue 其中之一>
frameworks: [\"<套件@版本範圍>\"]
severity_default: <CRITICAL|HIGH|MEDIUM|LOW>
---
## 觸發訊號
（diff 裡出現什麼樣的東西時要套用這條規則。要具體到可以比對，不要寫「當有問題時」。）

## 判準
（為什麼那是問題。寫資深 reviewer 實際的理由，不要寫教科書定義。）

## 嚴重度
CRITICAL：（什麼情況）
HIGH：（什麼情況）
MEDIUM：（什麼情況）

## 反例（不該報）
（什麼情況看起來像但不該報。這一節不能空著 —— 沒有反例的規則會製造雜訊。）

## 出處
（下面每一則意見的 html_url，一行一個，前面加 \"- \"）

意見：
${input}"

# 不加 2>/dev/null：這支腳本的 stdout 會被呼叫端（extract-rules-tfidf.sh）
# 用 `$(...)` 整段捕進 raw 變數，claude 的 stderr 不會混進那個變數——把
# stderr 丟到 /dev/null 純粹是把診斷（額度用盡、認證失效、工具被拒用等）
# 憑空丟掉，呼叫端唯一看得到的失敗訊號只剩 AGENT_FAILED 這個空殼，沒辦法
# 判斷是 prompt 的問題還是別的問題。這是這個專案已經付過三次代價的模式，
# brief 原本的參考實作在這裡就是這樣寫的，拿掉。
#
# --setting-sources "project"：不指定的話 claude -p 會連使用者全域的
# ~/.claude/ 設定（CLAUDE.md、agent 規則）一起載入，這支腳本呼叫的是單次、
# 唯讀的規則萃取任務，不需要也不該被呼叫者本機的全域偏好（例如另一份
# CLAUDE.md 裡的 commit 規則、agent 派工規則）影響輸出格式；同一份 prompt
# 在不同人的機器上跑出不一致的規則格式，會讓兩條萃取路線的比較混進格式
# 雜訊。lib/test-audit.sh、lib/pkb-prompts.sh 等既有的唯讀單次 claude -p
# 呼叫都帶這個旗標，這裡跟著同一個慣例。
# 除了 brief 原本就擋的 Write/Edit/NotebookEdit，這裡再多擋 Read/Grep/
# Glob/Bash/WebFetch/WebSearch/Task：這個任務唯一的素材是 stdin 餵進來的
# cluster JSON（已經整段嵌進 prompt），不需要探索任何檔案系統或發任何請求。
# 實測發現不擋的話，agent 偶爾會嘗試用 Read 去查 diff 裡提到的檔案路徑
# （例如 packages/core/middleware/middleware-module.ts）——但 claude -p 是
# 在這個 repo（mra 本身）底下執行，那些路徑屬於被抽樣的外部 repo，根本不
# 存在，白白燒掉 turn 預算，實測過一次因此撞上 --max-turns 4 直接失敗。
# prompt 走 stdin 不走 argv。實測 rails 層的大群（最多 1027 則成員，整段嵌進
# prompt 之後遠超 ARG_MAX）會讓 execve 直接回
# `claude: Argument list too long`，那一群連模型都沒呼叫到就失敗。
# `claude -p` 不帶引數時從 stdin 讀 prompt，改成這樣就沒有長度上限。
# MRA_REVIEW_EMIT_JSON 明確設成空字串（不是漏打值）：這支腳本可能在
# MRA_REVIEW_EMIT_JSON=1 的回測環境底下被呼叫，那個變數會讓 lib/review.sh
# 把診斷訊息改道 stderr，污染這裡要解析的模型輸出。
#
# 為什麼這裡自己寫重試迴圈，而不是直接呼叫 lib/claude-invoke.sh 的
# claude_invoke：claude_invoke 只能把引數重放給 claude，沒辦法重放 stdin。
# 它的重試迴圈在同一個行程裡重跑同一組 argv，繼承下來的 stdin 檔案描述符
# 位移是共用的，第一次嘗試讀完之後就停在 EOF。實測（把 prompt 用管線餵進
# claude_invoke，或用 `< 檔案` 重導都一樣）：第一次嘗試收到 15 bytes，重試
# 那次收到 0 bytes。也就是說直接共用的話，重試會拿一個「空 prompt」去問模型
# 然後把結果當成規則，那比不重試更糟。
#
# 「走 stdin」是硬需求（上面 ARG_MAX 那段的理由），「重試」也是硬需求，而
# claude_invoke 的介面同時滿足不了這兩件事。所以只有迴圈本身自己寫：每一輪
# 重新 `printf | ...`，stdin 就是全新的。判斷「這個失敗值不值得重試」的規則、
# 每次嘗試的逾時上限、以及把逾時真正套到整個行程群組的包裝，全部沿用
# lib/claude-invoke.sh 的既有實作，不在這裡另外寫一份會漂移的複本。
# 可調參數也刻意跟它共用同一組環境變數（MRA_CLAUDE_MAX_RETRIES、
# MRA_CLAUDE_RETRY_DELAY、MRA_CLAUDE_TIMEOUT_SECONDS、MRA_CLAUDE_BIN），
# 呼叫端不需要記兩套名字。
bin="${MRA_CLAUDE_BIN:-claude}"
max="${MRA_CLAUDE_MAX_RETRIES:-2}"
delay="${MRA_CLAUDE_RETRY_DELAY:-3}"

declare -a runner=()
tsecs="$(_claude_timeout_secs)"
_mra_bounded_runner runner "$tsecs" "$bin"

errf="$(mktemp "${TMPDIR:-/tmp}/rule-agent.XXXXXX")" || exit 1
trap 'rm -f "$errf"' EXIT

attempt=0
while :; do
  out="$(printf '%s' "$prompt" | MRA_REVIEW_EMIT_JSON='' "${runner[@]}" -p \
    --model "${MRA_RULE_AGENT_MODEL:-sonnet}" \
    --max-turns "${MRA_RULE_AGENT_MAX_TURNS:-4}" \
    --disallowedTools "Write,Edit,NotebookEdit,Read,Grep,Glob,Bash,WebFetch,WebSearch,Task" \
    --setting-sources "project" 2>"$errf")"
  rc=$?
  err="$(cat "$errf")"

  if [ "$rc" -eq 0 ] && [ -n "$out" ]; then
    printf '%s' "$out"
    exit 0
  fi

  # 退出 0 但沒有輸出也算暫時性失敗。額度尖峰時 claude 會這樣回，而呼叫端
  # 拿到空字串跟拿到失敗是分不出來的，所以在這裡就重試掉。
  if [ "$attempt" -lt "$max" ] && \
     { _claude_is_transient "$rc" "$err" || { [ "$rc" -eq 0 ] && [ -z "$out" ]; }; }; then
    attempt=$((attempt + 1))
    if [ "$rc" -eq 142 ]; then why="卡住，${tsecs} 秒後被砍掉"
    elif [ "$rc" -ne 0 ]; then why="退出碼 ${rc}"
    else why="空輸出"; fi
    # log_warn 預設印到 stdout，這裡一定要導到 stderr：這支腳本的 stdout 會被
    # 呼叫端整段捕成規則內容，一行進度訊息混進去就變成規則檔的一部分。
    log_warn "claude 暫時性失敗（${why}），${delay} 秒後重試第 ${attempt}/${max} 次" "rule-agent" >&2
    [ -n "$err" ] && printf '%s\n' "$err" | tail -3 | sed 's/^/    claude: /' >&2
    sleep "$delay"
    delay=$((delay * 2))
    continue
  fi

  # 放棄。stderr 一律交出去，不吞：呼叫端（extract-rules-*.sh）只會記下退出碼，
  # 事後要判斷是額度用盡還是認證失效，只能靠這幾行。
  if [ -n "$err" ]; then
    log_error "claude 失敗（退出碼 ${rc}），共嘗試 $((attempt + 1)) 次：$(printf '%s' "$err" | tail -5 | tr '\n' ' ')" "rule-agent"
  else
    log_error "claude 失敗（退出碼 ${rc}），共嘗試 $((attempt + 1)) 次，且沒有任何 stderr" "rule-agent"
  fi

  # 重試用完仍然是「退出 0 但空輸出」時不能跟著回 0。回 0 等於告訴呼叫端
  # 「成功，只是內容剛好是空的」，而呼叫端會把空字串當成一份產出往下送驗證。
  # 用一個自己的退出碼 65 回報，讓它落在呼叫端的 agent 失敗那一類，並在
  # stderr 留一個可以 grep 的 token。
  if [ "$rc" -eq 0 ]; then
    echo "RULE_AGENT_EMPTY_OUTPUT：重試 ${max} 次之後 claude 仍然退出 0 但沒有輸出" >&2
    exit 65
  fi
  exit "$rc"
done
