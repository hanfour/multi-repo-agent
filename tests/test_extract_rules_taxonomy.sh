#!/usr/bin/env bash
# B 路線：依 finding 分類萃取規則 (lib/taxonomy-classes.sh、
# scripts/extract-rules-taxonomy.sh)。
#
# task-5-brief.md 指定的 8 個案例是最低要求。後面是自己構造的畸形/邊界
# 輸入——前四個任務的教訓是 mutation testing 只驗「這行程式碼有作用」，手動
# 構造的畸形輸入才驗「這個函式的定義域涵蓋得夠嗎」。這裡額外覆蓋的，是對照
# scripts/extract-rules-tfidf.sh（A 路線）讀出來、brief 參考實作沒做到的
# 四個地方：_dropped.tsv 跨層截斷、缺 id_is_safe()、id 撞名會被靜默覆蓋、
# summary 的 agent 失敗數漏印。
set -uo pipefail
MRA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$MRA_DIR/lib/corpus-targets.sh"
source "$MRA_DIR/lib/rule-schema.sh"
source "$MRA_DIR/lib/taxonomy-classes.sh"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/extract-rules-taxonomy-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
IN="$TMP/in"; STUB="$TMP/stub"; OUT="$TMP/out"
mkdir -p "$IN" "$STUB" "$OUT"

errors=0; pass=0
ok()   { echo "PASS: $1"; pass=$((pass+1)); }
fail() { echo "FAIL: $1"; errors=$((errors+1)); }
eq()   { if [[ "$2" == "$3" ]]; then ok "$1"; else fail "$1 — expected [$2] got [$3]"; fi; }
has()  { case "$2" in *"$3"*) ok "$1" ;; *) fail "$1 — 沒看到「$3」：$2" ;; esac; }
lacks(){ case "$2" in *"$3"*) fail "$1 — 不該看到「$3」：$2" ;; *) ok "$1" ;; esac; }

run_extract() {
  # $1=corpus jsonl $2=layer $3=out 目錄 $4=agent 命令
  MRA_RULE_AGENT_CMD="$4" bash "$MRA_DIR/scripts/extract-rules-taxonomy.sh" \
    --corpus "$1" --layer "$2" --out "$3"
}

# =============================================================================
# stub agent：讀 stdin 的 {class_id, class_name, layer, members} JSON，吐一份
# 合格的規則檔。id 用 <layer>-<class_id>，跟 taxonomy_prompt_prefix 要求的
# 格式一致，也保證同一次跑裡各 class 產出的檔名互不相同。
# =============================================================================
write_agent_stub() {
  cat > "$STUB/agent" <<'SH'
#!/usr/bin/env bash
input="$(cat)"
layer="$(printf '%s' "$input" | jq -r '.layer')"
cid="$(printf '%s' "$input" | jq -r '.class_id')"
cat <<MD
---
id: ${layer}-${cid}
layer: ${layer}
frameworks: ["stub@>=1"]
severity_default: HIGH
---
## 觸發訊號
stub 觸發條件

## 判準
stub 判準內容

## 嚴重度
CRITICAL：stub
HIGH：stub
MEDIUM：stub

## 反例（不該報）
stub 反例

## 出處
$(printf '%s' "$input" | jq -r '.members[] | "- " + .html_url')
MD
SH
  chmod +x "$STUB/agent"
}
write_agent_stub

# 一個 react 語料檔，讓每一類都撈得到 >=3 則（用來測「產出」路徑，不是
# 「丟棄」路徑）。每一類至少放 3 則貼著該類關鍵詞寫的假 comment。
write_rich_corpus() {
  printf '%s\n' \
    '{"body":"other routes have a beforeLoad guard, this one is missing it","html_url":"https://x/mc1","path":"a.tsx"}' \
    '{"body":"should also add the same check here, consistent with the sibling route","html_url":"https://x/mc2","path":"a.tsx"}' \
    '{"body":"forgot to add the guard elsewhere we already do this","html_url":"https://x/mc3","path":"a.tsx"}' \
    '{"body":"this hook uses a shared instance, not scoped per-item key","html_url":"https://x/ss1","path":"b.tsx"}' \
    '{"body":"looks like a singleton, same reference is reused across items","html_url":"https://x/ss2","path":"b.tsx"}' \
    '{"body":"global shared state here, not scoped to the row","html_url":"https://x/ss3","path":"b.tsx"}' \
    '{"body":"actually returns undefined here, this behaves differently than you think","html_url":"https://x/fs1","path":"c.tsx"}' \
    '{"body":"in strict mode this will be called twice","html_url":"https://x/fs2","path":"c.tsx"}' \
    '{"body":"this changes the existing behavior, is truthy in this case","html_url":"https://x/fs3","path":"c.tsx"}' \
    '{"body":"only handles the loading case, what if the request fails","html_url":"https://x/sc1","path":"d.tsx"}' \
    '{"body":"there is a third case, the error state is dropped here","html_url":"https://x/sc2","path":"d.tsx"}' \
    '{"body":"isPending goes straight to loading without an error branch","html_url":"https://x/sc3","path":"d.tsx"}' \
    '{"body":"this test does not fail if the implementation breaks","html_url":"https://x/tq1","path":"e.test.tsx"}' \
    '{"body":"mocks the entire module, the assertion would still pass either way","html_url":"https://x/tq2","path":"e.test.tsx"}' \
    '{"body":"not actually test the failure path here","html_url":"https://x/tq3","path":"e.test.tsx"}' \
    '{"body":"this cache key goes stale, needs invalidate on mutation","html_url":"https://x/ci1","path":"f.tsx"}' \
    '{"body":"the query is now out of date, should refetch after this","html_url":"https://x/ci2","path":"f.tsx"}' \
    '{"body":"invalidate the other cache key too, it reads stale data","html_url":"https://x/ci3","path":"f.tsx"}' \
    '{"body":"this guard only runs when the flag is set, can be bypassed","html_url":"https://x/eg1","path":"g.tsx"}' \
    '{"body":"the check can be skipped, guard doesnt cover this branch","html_url":"https://x/eg2","path":"g.tsx"}' \
    '{"body":"this wont trigger, the guard does not cover this case","html_url":"https://x/eg3","path":"g.tsx"}' \
    '{"body":"off by one here, rounding is wrong for this edge case","html_url":"https://x/dl1","path":"h.tsx"}' \
    '{"body":"timezone handling is wrong, precision is lost in this edge case","html_url":"https://x/dl2","path":"h.tsx"}' \
    '{"body":"currency rounding is off by one cent here","html_url":"https://x/dl3","path":"h.tsx"}' \
    > "$IN/rich-react.jsonl"
}
write_rich_corpus

# =============================================================================
# 案例 1-8：brief 指定的最低要求
# =============================================================================

test_all_eight_classes_defined() {
  eq "定義了 8 類" "8" "$(taxonomy_classes | wc -l | tr -d ' ')"
}

test_class_ids_unique() {
  eq "class_id 沒有重複" \
    "$(taxonomy_classes | cut -f1 | wc -l | tr -d ' ')" \
    "$(taxonomy_classes | cut -f1 | sort -u | wc -l | tr -d ' ')"
}

test_search_finds_matching_comment() {
  printf '%s\n' \
    '{"body":"The other routes have a beforeLoad guard, this one is missing it","html_url":"https://x/1","path":"a.tsx"}' \
    '{"body":"nit: rename this variable","html_url":"https://x/2","path":"b.tsx"}' \
    > "$IN/react.jsonl"
  local hits; hits="$(taxonomy_search missing-convention "$IN/react.jsonl" 10 | wc -l | tr -d ' ')"
  eq "撈到 1 則" "1" "$hits"
}

test_search_is_case_insensitive() {
  printf '{"body":"MISSING a null check here","html_url":"https://x/3","path":"c.tsx"}\n' > "$IN/r2.jsonl"
  eq "大小寫不敏感" "1" "$(taxonomy_search missing-convention "$IN/r2.jsonl" 10 | wc -l | tr -d ' ')"
}

test_unknown_class_fails_loudly() {
  local out rc
  out="$(taxonomy_search no-such-class "$IN/react.jsonl" 10 2>&1)"; rc=$?
  [ "$rc" -ne 0 ] && ok "未知類別退出碼非 0" || fail "應退出非 0"
  has "印出 UNKNOWN_CLASS" "$out" "UNKNOWN_CLASS"
}

test_respects_limit() {
  : > "$IN/many.jsonl"
  for i in $(seq 1 20); do
    printf '{"body":"missing a guard","html_url":"https://x/%s","path":"z.tsx"}\n' "$i" >> "$IN/many.jsonl"
  done
  eq "上限生效" "5" "$(taxonomy_search missing-convention "$IN/many.jsonl" 5 | wc -l | tr -d ' ')"
}

# 撈不到足夠實例的類別要丟棄並記錄，不要硬產一條沒有出處的規則
test_class_with_too_few_hits_is_dropped() {
  printf '{"body":"nit: typo"}\n' > "$IN/sparse.jsonl"
  local out_dir="$TMP/out-sparse"; mkdir -p "$out_dir"
  run_extract "$IN/sparse.jsonl" react "$out_dir" "$STUB/agent" >/dev/null 2>&1
  has "丟棄記錄有內容" "$(cat "$out_dir/_dropped.tsv")" "missing-convention"
}

test_output_passes_validation() {
  run_extract "$IN/rich-react.jsonl" react "$OUT" "$STUB/agent" >/dev/null 2>&1
  local f any=0
  for f in "$OUT"/*.md; do
    [ -e "$f" ] || continue
    any=1
    rule_validate "$f" || fail "產出沒通過驗證：$f"
  done
  [ "$any" -eq 1 ] && ok "所有產出都通過 rule_validate（且確實有產出）" \
    || fail "沒有任何規則檔產出，這個測試沒有驗到東西"
}

# =============================================================================
# 案例 9+：對照 A 路線抓出來、brief 參考實作沒做到的地方
# =============================================================================

# _dropped.tsv 若每次呼叫都截斷重寫，Step 7 對五層各呼叫一次、全部寫進同一個
# --out 目錄時，跑完只會剩最後一層的紀錄。兩次呼叫（模擬兩層）都要留在檔案裡。
test_dropped_log_accumulates_across_layers_sharing_out_dir() {
  local out_dir="$TMP/out-shared-drop"; mkdir -p "$out_dir"
  printf '{"body":"nit: typo layerA-marker"}\n' > "$IN/sparse-a.jsonl"
  printf '{"body":"nit: typo layerB-marker"}\n' > "$IN/sparse-b.jsonl"
  run_extract "$IN/sparse-a.jsonl" layerA "$out_dir" "$STUB/agent" >/dev/null 2>&1
  run_extract "$IN/sparse-b.jsonl" layerB "$out_dir" "$STUB/agent" >/dev/null 2>&1
  has "第一層（layerA）的丟棄紀錄還在" "$(cat "$out_dir/_dropped.tsv")" "layerA"
  has "第二層（layerB）的丟棄紀錄也在" "$(cat "$out_dir/_dropped.tsv")" "layerB"
}

# agent 吐出的 id 帶路徑分隔字元（企圖跳脫 $OUT 目錄）：不該被拿去當 mv 的
# 目的地路徑，要在寫檔之前就攔下來，也不該在 $OUT 之外留下任何東西。
# brief 最初的參考實作沒有呼叫 id_is_safe()，這個測試是專門盯著這個缺口。
test_unsafe_id_with_path_separator_is_rejected() {
  cat > "$STUB/traversal-agent" <<'SH'
#!/usr/bin/env bash
cat >/dev/null
cat <<MD
---
id: ../../../tmp/mra-taxonomy-path-traversal-probe
layer: react
frameworks: ["stub@>=1"]
severity_default: HIGH
---
## 觸發訊號
x

## 判準
x

## 嚴重度
CRITICAL：x
HIGH：x
MEDIUM：x

## 反例（不該報）
x

## 出處
- https://x/a
- https://x/b
- https://x/c
MD
SH
  chmod +x "$STUB/traversal-agent"
  rm -f /tmp/mra-taxonomy-path-traversal-probe.md
  local out_dir="$TMP/out-traversal"; mkdir -p "$out_dir"
  local out
  out="$(run_extract "$IN/rich-react.jsonl" react "$out_dir" "$STUB/traversal-agent" 2>&1)"
  has "含路徑分隔字元的 id 被 RULE_REJECTED" "$out" "RULE_REJECTED"
  has "訊息指名是不安全字元" "$out" "不安全字元"
  eq "沒有寫到 \$OUT 目錄之外" "0" "$([ -f /tmp/mra-taxonomy-path-traversal-probe.md ] && echo 1 || echo 0)"
  eq "\$OUT 目錄裡沒有產出規則檔" "0" "$(find "$out_dir" -maxdepth 1 -name '*.md' | wc -l | tr -d ' ')"
  rm -f /tmp/mra-taxonomy-path-traversal-probe.md
}

# 兩個不同的 class，agent 都吐出同一個 id：第一個成功落地，第二個不該悄悄
# 覆蓋掉第一個檔案——那是把一條已經驗證過的規則靜默銷毀。brief 最初的參考
# 實作在 mv 到 $OUT/<id>.md 之前沒有檢查 dest 是否已存在，這個測試專門盯著
# 這個缺口。用一支永遠吐同一個 id 的 stub，對同一個 --out 目錄跑兩次不同
# 語料（模擬兩個不同 class 撞出同一個 id）。
test_duplicate_id_does_not_overwrite() {
  cat > "$STUB/collide-agent" <<'SH'
#!/usr/bin/env bash
input="$(cat)"
cat <<MD
---
id: react-collide
layer: react
frameworks: ["stub@>=1"]
severity_default: HIGH
---
## 觸發訊號
撞名觸發條件

## 判準
撞名判準內容

## 嚴重度
CRITICAL：撞名
HIGH：撞名
MEDIUM：撞名

## 反例（不該報）
撞名反例

## 出處
$(printf '%s' "$input" | jq -r '.members[] | "- " + .html_url')
MD
SH
  chmod +x "$STUB/collide-agent"

  # 兩份不同語料，各自有 3 則不重複的 missing-convention 命中，出處內容
  # 真的不同——這樣「既有檔案沒被覆蓋」這個斷言才有辨別力。
  printf '%s\n' \
    '{"body":"should also add this, consistent with the pattern","html_url":"https://x/first-a"}' \
    '{"body":"missing a guard here, forgot to add it","html_url":"https://x/first-b"}' \
    '{"body":"other routes have this check","html_url":"https://x/first-c"}' \
    > "$IN/collide-first.jsonl"
  printf '%s\n' \
    '{"body":"should also add this elsewhere we already do it","html_url":"https://x/second-a"}' \
    '{"body":"missing a check, needs a guard","html_url":"https://x/second-b"}' \
    '{"body":"same pattern used in other routes have it too","html_url":"https://x/second-c"}' \
    > "$IN/collide-second.jsonl"

  local out_dir="$TMP/out-collide"; mkdir -p "$out_dir"
  run_extract "$IN/collide-first.jsonl" react "$out_dir" "$STUB/collide-agent" >/dev/null 2>&1
  local out
  out="$(run_extract "$IN/collide-second.jsonl" react "$out_dir" "$STUB/collide-agent" 2>&1)"

  eq "撞名時只有一個檔案落地" "1" "$(ls "$out_dir"/*.md 2>/dev/null | wc -l | tr -d ' ')"
  has "撞名被記為 RULE_REJECTED" "$out" "RULE_REJECTED"
  has "訊息指名是撞名" "$out" "撞名"
  has "既有檔案的出處沒被覆蓋（仍是第一次跑的 first-a/b/c）" \
    "$(cat "$out_dir/react-collide.md")" "https://x/first-a"
  lacks "既有檔案沒被第二次跑的內容（second-a/b/c）取代" \
    "$(cat "$out_dir/react-collide.md")" "https://x/second-a"
}

# agent 指令本身以非 0 退出：不落地成規則檔，落地成 _agent_failed.tsv，且
# summary 要正確報出 agent 失敗的數字。brief 最初的參考實作最後那句 printf
# 有 5 個 %s 佔位卻只傳了 4 個變數（少了 $agent_failed），"agent 失敗" 那個
# 數字永遠印成空字串——這個測試專門盯著這個缺口。
test_agent_command_failure_summary_prints_correct_count() {
  cat > "$STUB/failing-agent" <<'SH'
#!/usr/bin/env bash
cat >/dev/null
echo "模擬 agent 額度用盡或崩潰" >&2
exit 17
SH
  chmod +x "$STUB/failing-agent"
  local out_dir="$TMP/out-agent-failed"; mkdir -p "$out_dir"
  local out
  out="$(run_extract "$IN/rich-react.jsonl" react "$out_dir" "$STUB/failing-agent" 2>&1)"

  eq "agent 失敗不落地成任何規則檔" "0" "$(ls "$out_dir"/*.md 2>/dev/null | wc -l | tr -d ' ')"
  has "stderr 印出 AGENT_FAILED" "$out" "AGENT_FAILED"
  has "stderr 印出 agent 的退出碼" "$out" "退出碼 17"
  eq "_agent_failed.tsv 恰有 8 筆（8 類全部命中門檻，全部呼叫 agent，全部失敗）" \
    "8" "$(grep -c . "$out_dir/_agent_failed.tsv")"
  has "summary 印出正確的 agent 失敗數（8），不是空字串" "$out" "agent 失敗 8"
}

# ARG_MAX 迴歸測試：40 則候選、每則 body 都填到接近 30KB，總量刻意超過這台
# 機器 `getconf ARG_MAX` 量到的 1,048,576 bytes。brief 最初的參考實作用
# `jq -n --argjson m "$(...)"` 把撈到的內容整段塞進 argv 再傳給 jq——這正是
# scripts/rule-agent.sh 檔頭記錄的那個 ARG_MAX 事故的同類型坑，只是換了個
# 發生的位置（那次是傳給 claude -p，這次會是傳給 jq -n）。改成讓 jq 從
# stdin slurp 之後，這裡驗證大量資料不會讓腳本用 execve 失敗中止。
test_large_payload_does_not_hit_arg_max() {
  local big; big="$(printf 'x%.0s' $(seq 1 30000))"
  : > "$IN/argmax.jsonl"
  local i
  for i in $(seq 1 40); do
    printf '{"body":"missing a guard here %s %s","html_url":"https://x/argmax-%s","path":"z.tsx"}\n' \
      "$i" "$big" "$i" >> "$IN/argmax.jsonl"
  done
  local size; size="$(wc -c < "$IN/argmax.jsonl" | tr -d ' ')"
  [ "$size" -gt 1048576 ] && ok "測試語料確實超過本機 ARG_MAX（$size bytes）" \
    || fail "測試語料只有 $size bytes，沒有超過 ARG_MAX，這個測試沒有驗到東西"

  local out_dir="$TMP/out-argmax"; mkdir -p "$out_dir"
  local out rc
  out="$(run_extract "$IN/argmax.jsonl" react "$out_dir" "$STUB/agent" 2>&1)"; rc=$?
  eq "大量候選資料不會讓腳本失敗退出" "0" "$rc"
  lacks "不會出現 Argument list too long" "$out" "Argument list too long"
  eq "大量候選資料仍然成功產出規則檔" "1" "$(ls "$out_dir"/*.md 2>/dev/null | wc -l | tr -d ' ')"
}

# agent 吐空字串：沒有 id 欄位，走 REJECTED 路徑，不當成崩潰處理。
test_agent_returns_empty_string() {
  cat > "$STUB/empty-agent" <<'SH'
#!/usr/bin/env bash
cat >/dev/null
printf ''
SH
  chmod +x "$STUB/empty-agent"
  local out_dir="$TMP/out-empty"; mkdir -p "$out_dir"
  local out
  out="$(run_extract "$IN/rich-react.jsonl" react "$out_dir" "$STUB/empty-agent" 2>&1)"
  has "空字串輸出被記為 RULE_REJECTED" "$out" "RULE_REJECTED"
  eq "空字串輸出不落地成規則檔" "0" "$(ls "$out_dir"/*.md 2>/dev/null | wc -l | tr -d ' ')"
}

# corpus 檔缺 --corpus 旗標指到的路徑：要在跑任何一類之前就失敗，不要對空
# 字串或不存在的檔案悄悄往下跑。
test_missing_corpus_flag_fails_loudly() {
  local out rc
  out="$(run_extract "$IN/does-not-exist.jsonl" react "$TMP/out-missing" "$STUB/agent" 2>&1)"; rc=$?
  [ "$rc" -ne 0 ] && ok "缺 corpus 檔退出碼非 0" || fail "應退出非 0"
  has "印出 CORPUS_MISSING" "$out" "CORPUS_MISSING"
}

# --layer 缺漏：要在跑任何一類之前就失敗。
test_missing_layer_flag_fails_loudly() {
  local out rc
  out="$(MRA_RULE_AGENT_CMD="$STUB/agent" bash "$MRA_DIR/scripts/extract-rules-taxonomy.sh" \
    --corpus "$IN/rich-react.jsonl" --out "$TMP/out-no-layer" 2>&1)"; rc=$?
  [ "$rc" -ne 0 ] && ok "缺 --layer 退出碼非 0" || fail "應退出非 0"
  has "印出 LAYER_MISSING" "$out" "LAYER_MISSING"
}

# MRA_RULE_AGENT_CMD 沒設定：要在跑任何一類之前就失敗，不要讓後面每一類都
# 個別撞到「command not found」才發現。
test_missing_agent_cmd_fails_loudly() {
  local out rc
  out="$(bash "$MRA_DIR/scripts/extract-rules-taxonomy.sh" \
    --corpus "$IN/rich-react.jsonl" --layer react --out "$TMP/out-no-agent" 2>&1)"; rc=$?
  [ "$rc" -ne 0 ] && ok "MRA_RULE_AGENT_CMD 未設定時退出碼非 0" || fail "應退出非 0"
  has "印出 MRA_RULE_AGENT_CMD 未設定" "$out" "MRA_RULE_AGENT_CMD 未設定"
}

# MRA_TAXONOMY_MIN_HITS 被設成非數字：要在跑任何一類之前就失敗，而不是讓
# `[ "$n" -lt "$MIN_HITS" ]` 用非整數值去比較、丟出 bash 自己的
# "integer expression expected" 錯誤（那不是這支腳本自己的診斷）。
test_non_numeric_min_hits_fails_loudly() {
  local out rc
  out="$(MRA_TAXONOMY_MIN_HITS=abc MRA_RULE_AGENT_CMD="$STUB/agent" \
    bash "$MRA_DIR/scripts/extract-rules-taxonomy.sh" \
    --corpus "$IN/rich-react.jsonl" --layer react --out "$TMP/out-bad-min-hits" 2>&1)"; rc=$?
  [ "$rc" -ne 0 ] && ok "非數字 MRA_TAXONOMY_MIN_HITS 退出碼非 0" || fail "應退出非 0"
  has "印出 MRA_TAXONOMY_MIN_HITS 必須是非負整數" "$out" "MRA_TAXONOMY_MIN_HITS 必須是非負整數"
  lacks "不會洩漏 bash 自己的 integer expression 錯誤" "$out" "integer expression expected"
}

# MRA_TAXONOMY_MIN_HITS 設成 0：所有類別都不該被丟棄（連 0 則命中的類別也
# 通過門檻），驗證這個環境變數真的有作用，不是被忽略的死參數。
test_min_hits_zero_lets_everything_through_the_threshold() {
  printf '{"body":"nit: typo, nothing matches any taxonomy keyword whatsoever"}\n' > "$IN/zero-hits.jsonl"
  local out_dir="$TMP/out-min-hits-zero"; mkdir -p "$out_dir"
  local out
  out="$(MRA_TAXONOMY_MIN_HITS=0 run_extract "$IN/zero-hits.jsonl" react "$out_dir" "$STUB/agent" 2>&1)"
  has "MIN_HITS=0 時沒有任何類別被丟棄" "$out" "丟棄 0"
}

test_all_eight_classes_defined
test_class_ids_unique
test_search_finds_matching_comment
test_search_is_case_insensitive
test_unknown_class_fails_loudly
test_respects_limit
test_class_with_too_few_hits_is_dropped
test_output_passes_validation
test_dropped_log_accumulates_across_layers_sharing_out_dir
test_unsafe_id_with_path_separator_is_rejected
test_duplicate_id_does_not_overwrite
test_agent_command_failure_summary_prints_correct_count
test_large_payload_does_not_hit_arg_max
test_agent_returns_empty_string
test_missing_corpus_flag_fails_loudly
test_missing_layer_flag_fails_loudly
test_missing_agent_cmd_fails_loudly
test_non_numeric_min_hits_fails_loudly
test_min_hits_zero_lets_everything_through_the_threshold

# --- 語料壞掉要跟「實例不足」分開報 ---------------------------------------
# taxonomy_search 的退出碼原本被丟棄，語料檔有一行截斷的 JSON 時 jq 失敗、
# 撈到 0 則，然後被記成「撈到 0 則，少於 3」丟棄。那兩件事的處置完全不同：
# 前者要重跑 materialize，後者是這個類別在這一層真的沒有實例。
BROKEN="$TMP/broken-corpus.jsonl"
printf '%s\n' '{"body":"missing test coverage for the new branch","url":"https://x/1"}' > "$BROKEN"
printf '%s\n' '{"body":"no test added for this convention","url":"https://x/2"}' >> "$BROKEN"
printf '%s' '{"body":"這一行沒有收尾' >> "$BROKEN"

out_broken="$(run_extract "$BROKEN" common "$TMP/out-broken" true 2>&1)"
rc_broken=$?
[ "$rc_broken" -ne 0 ] && ok "語料壞掉時退出碼非 0" || fail "應該退出非 0"
has "用 CORPUS_SEARCH_FAILED 這個 token 報" "$out_broken" "CORPUS_SEARCH_FAILED"
has "訊息說明是語料本身有問題" "$out_broken" "語料本身有問題"
lacks "不該被誤報成撈到 0 則" "$out_broken" "少於"

# 對照：語料正常但某個類別真的沒有實例時，仍然走「丟棄」那條路
CLEAN="$TMP/clean-corpus.jsonl"
printf '%s\n' '{"body":"完全無關的內容","url":"https://x/1"}' > "$CLEAN"
out_clean="$(run_extract "$CLEAN" common "$TMP/out-clean" true 2>&1)"
lacks "語料正常時不報 CORPUS_SEARCH_FAILED" "$out_clean" "CORPUS_SEARCH_FAILED"
if [ -s "$TMP/out-clean/_dropped.tsv" ]; then
  ok "實例不足的類別仍然被記進 _dropped.tsv"
else
  fail "實例不足的類別沒有被記錄"
fi

echo "---"; echo "Passed: $pass"; echo "Failed: $errors"
exit $((errors > 0 ? 1 : 0))
