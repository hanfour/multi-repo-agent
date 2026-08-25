#!/usr/bin/env bash
# B 路線的骨架：八類的定義與檢索關鍵詞，來自
# docs/superpowers/notes/2026-backtest-finding-taxonomy.md 對階段二基準線 47
# 條漏抓的分類。class_id 用英文（會變成規則檔名的一部分），中文名用於 log。
#
# 檢索關鍵詞是「reviewer 講這一類問題時實際會用的字」，不是分類名稱的翻譯。
# 例如「缺席」那一類，reviewer 不會說 "absence"，會說 "should also"、
# "missing"、"other routes have"、"consistent with"。
#
# 這組詞最初是從 A 路線 30 條 comment 與語料抽樣歸納的草案，沒有實際跑過。
# 對五層真實語料（61,362 則）跑過一次命中數之後，兩類在原始版本於 vue 層
# 撈不到 3 則（framework-semantics 撈到 0、error-guard-condition 撈到 2），
# 因此調整了這兩類的關鍵詞——調整細節與依據見 task-5-report.md。其餘六類
# 原始版本在五層都已經 >=3 則，未改動。
#
# 一則意見可能同時命中多類，不去重 —— 同一則意見支持兩條規則是正常的，
# 強制歸一類會丟掉資訊。
taxonomy_classes() {
  cat <<'CLASSES'
missing-convention	缺席：應該有而沒有	should also|missing|other .* (have|has)|consistent with|same pattern|elsewhere we|forgot to add|needs? a? ?(guard|check|test)
shared-state-scope	狀態範圍：共用了不該共用的狀態	shared (state|instance)|per-.* key|not scoped|same reference|singleton|global
framework-semantics	框架語意	actually returns|in (rails|react|vue|nest) this|behaves? differently|is truthy|will be called twice|strict ?mode|diverges? from|changes? the (existing |current )?behavior|this is intentional|actual(ly)? (returns|is|does)
missing-state-case	狀態遺漏：三態當兩態	loading|error state|only handles|what if .* fails|third case|pending
test-quality	測試品質	test (does not|doesn't) (fail|verify)|mock(s|ed)? (the )?(entire|whole)|assertion|would still pass|not actually test
cache-invalidation	快取一致性	invalidate|stale|cache key|refetch|out of date
error-guard-condition	錯誤守衛：有檢查但條件錯	only (runs|checks|works|applies) when|bypass(ed|es)?|guard (does not|doesn't|won't)|skips? when|can be skipped|won't (run|trigger|fire|catch)|doesn't (run|trigger|fire|catch) (if|when)
domain-logic	領域與邏輯	off by one|rounding|timezone|currency|precision|edge case
CLASSES
}

# taxonomy_search <class_id> <jsonl> [上限=40] — 從語料撈出該類的候選意見，
# 輸出 JSONL（jq -c 一則一行）。
#
# 未知 class_id：印 UNKNOWN_CLASS 到 stderr，退出碼 1。
# corpus 檔不存在或是空檔：印 CORPUS_MISSING 到 stderr，退出碼 1。
#
# 用 jq 的 test() 做大小寫不敏感比對。body 為 null 的行已在 Task 1 濾掉，
# 但仍加 // "" 防禦：語料是外部資料，不要假設。
taxonomy_search() {
  local class_id="$1" jsonl="$2" limit="${3:-40}"
  local pattern
  pattern="$(taxonomy_classes | TAX_ID="$class_id" awk -F'\t' \
    '$1 == ENVIRON["TAX_ID"] { print $3; found=1 } END { exit !found }')" || {
    printf 'UNKNOWN_CLASS\t%s\n' "$class_id" >&2
    return 1
  }
  [ -s "$jsonl" ] || { printf 'CORPUS_MISSING\t%s\n' "$jsonl" >&2; return 1; }

  # 用 jq 自己的 limit() 取筆數，不接 `| head -N`。管線那個寫法有兩個問題：
  # head 配夠了就退出，jq 還在寫就吃到 SIGPIPE 回 141；更要緊的是 jq 真正的
  # 失敗（語料檔有一行截斷的 JSON、檔案讀不到）也會被管線吃掉，呼叫端看到的
  # 只是「撈到 0 則」。實測一行截斷的 JSON 讓 8 個類別裡的 7 個被誤報成
  # 「實例不足」而丟棄，而真正的原因是語料壞了。
  #
  # 這裡不加 pipefail 而是整段拿掉管線：pipefail 只會把那個 141 變成另一個
  # 難解讀的失敗，拿掉管線才讓 jq 的退出碼就是這個函式的退出碼。
  #
  # -n 搭配 inputs 逐行讀，不是把整個檔案 slurp 進記憶體：最大的一層是 40MB
  # 兩萬行，符合 pattern 的通常是幾十則，limit() 收滿就停。
  jq -c -n --arg p "$pattern" --argjson lim "$limit" \
    '[inputs | select((.body // "") | test($p; "i"))] | limit($lim; .[])' "$jsonl"
}

# taxonomy_prompt_prefix <class_id> <class_name> <layer> — B 路線的 prompt
# 前綴。骨架已定，agent 的工作是填內容而不是決定主題——這是它與 A 路線最
# 實質的差別，A 的 agent 要自己歸納群在講什麼。
#
# 定義在 Step 1 就跟 taxonomy_classes/taxonomy_search 放在同一支檔案：
# scripts/extract-rules-taxonomy.sh 會呼叫它，如果晚一步寫會在那支腳本先
# 寫出來時就撞上「command not found」。
taxonomy_prompt_prefix() {
  local class_id="$1" class_name="$2" layer="$3"
  cat <<EOF
以下是 ${layer} 層語料中，屬於「${class_name}」這一類的 review 意見。

這一類的定義：reviewer 指出的不是「這行寫錯了」，而是「這裡還應該做某件事」
或「這個情況沒有被考慮到」。回測資料顯示這是目前 reviewer 最大的盲區：
47 條漏抓有 51% 屬於這種形狀，六個 CRITICAL 有五個在裡面。

規則的 id 請用 ${layer}-${class_id} 開頭。

「觸發訊號」要寫成「diff 裡出現什麼樣的變更時，要去確認什麼」，
而不是「注意某某寫法」—— 前者會讓 reviewer 去看 diff 以外的東西，那正是
這一類問題需要的。
EOF
}
