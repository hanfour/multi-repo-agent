#!/usr/bin/env bash
# scripts/rule-agent.sh — 讀 stdin 的群組 JSON，呼叫 claude 產出 canonical 規則。
# 兩條萃取路線共用這支，差別只在餵進來的 JSON 形狀與 prompt 前綴。
set -uo pipefail
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
printf '%s' "$prompt" | MRA_REVIEW_EMIT_JSON='' claude -p \
  --model "${MRA_RULE_AGENT_MODEL:-sonnet}" \
  --max-turns "${MRA_RULE_AGENT_MAX_TURNS:-4}" \
  --disallowedTools "Write,Edit,NotebookEdit,Read,Grep,Glob,Bash,WebFetch,WebSearch,Task" \
  --setting-sources "project"
