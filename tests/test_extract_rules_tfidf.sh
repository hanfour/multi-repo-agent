#!/usr/bin/env bash
# A 路線第二步：每個主題群交給 agent 產出一條 canonical 規則
# (scripts/extract-rules-tfidf.sh)。
#
# agent 呼叫用 stub（MRA_RULE_AGENT_CMD 指到一個吐固定內容的腳本）：這裡驗的
# 是流程本身（丟棄門檻、id 從產出讀回、驗證、不合格留底），不是 agent 產出的
# 品質——品質是 scripts/rule-agent.sh 接真的 claude 之後才有意義的問題。
#
# 前 5 個案例是 task-4-brief.md 指定的最低要求。後面是自己構造的畸形/邊界
# 輸入——前三個任務的教訓是 mutation testing 只驗「這行程式碼有作用」，手動
# 構造的畸形輸入才驗「這個函式的定義域涵蓋得夠嗎」。
set -uo pipefail
MRA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$MRA_DIR/lib/corpus-targets.sh"
source "$MRA_DIR/lib/rule-schema.sh"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/extract-rules-tfidf-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
IN="$TMP/in"; STUB="$TMP/stub"
OUT="$TMP/out"; OUT2="$TMP/out2"; OUT3="$TMP/out3"
mkdir -p "$IN" "$STUB" "$OUT" "$OUT2" "$OUT3"

errors=0; pass=0
ok()   { echo "PASS: $1"; pass=$((pass+1)); }
fail() { echo "FAIL: $1"; errors=$((errors+1)); }
eq()   { if [[ "$2" == "$3" ]]; then ok "$1"; else fail "$1 — expected [$2] got [$3]"; fi; }
has()  { case "$2" in *"$3"*) ok "$1" ;; *) fail "$1 — 沒看到「$3」：$2" ;; esac; }
lacks(){ case "$2" in *"$3"*) fail "$1 — 不該看到「$3」：$2" ;; *) ok "$1" ;; esac; }

run_extract() {
  # $1=clusters 檔 $2=out 目錄 $3=agent 命令，其餘照舊透過 env 傳
  MRA_RULE_AGENT_CMD="$3" bash "$MRA_DIR/scripts/extract-rules-tfidf.sh" \
    --clusters "$1" --out "$2"
}

# =============================================================================
# stub agent：讀 stdin 的群組 JSON，吐一份合格的規則檔。id 帶 cluster id 以
# 保證同一次跑裡各群產出的檔名互不相同。
# =============================================================================
write_agent_stub() {
  cat > "$STUB/agent" <<'SH'
#!/usr/bin/env bash
input="$(cat)"
cid="$(printf '%s' "$input" | jq -r '.cluster')"
cat <<MD
---
id: nestjs-stub-rule-${cid}
layer: nestjs
frameworks: ["@nestjs/core@>=9"]
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

# =============================================================================
# 案例 1-5：brief 指定的最低要求
# =============================================================================

test_drops_clusters_with_too_few_sources() {
  # 一群 5 則、一群 2 則（出處不足三則）
  printf '%s\n' \
    '{"cluster":0,"n":5,"top_terms":["scope"],"members":[{"html_url":"https://x/1"},{"html_url":"https://x/2"},{"html_url":"https://x/3"},{"html_url":"https://x/4"},{"html_url":"https://x/5"}]}' \
    '{"cluster":1,"n":2,"top_terms":["test"],"members":[{"html_url":"https://x/6"},{"html_url":"https://x/7"}]}' \
    > "$IN/nestjs-clusters.jsonl"
  run_extract "$IN/nestjs-clusters.jsonl" "$OUT" "$STUB/agent" >/dev/null 2>&1
  eq "只產出 1 個規則檔" "1" "$(ls "$OUT"/*.md 2>/dev/null | wc -l | tr -d ' ')"
  has "被丟棄的群有記錄" "$(cat "$OUT/_dropped.tsv")" "1"
}

test_dropped_log_names_the_topic() {
  has "丟棄記錄含 top_terms" "$(cat "$OUT/_dropped.tsv")" "test"
}

test_output_passes_validation() {
  local f
  for f in "$OUT"/*.md; do
    rule_validate "$f" || fail "產出的規則檔沒通過驗證：$f"
  done
  ok "所有產出都通過 rule_validate"
}

test_invalid_agent_output_is_rejected() {
  cat > "$STUB/bad-agent" <<'SH'
#!/usr/bin/env bash
cat >/dev/null
echo "這不是規則檔，只是一段散文"
SH
  chmod +x "$STUB/bad-agent"
  local out
  out="$(run_extract "$IN/nestjs-clusters.jsonl" "$OUT2" "$STUB/bad-agent" 2>&1)"
  has "印出 RULE_REJECTED" "$out" "RULE_REJECTED"
  eq "不合格的產出不落地" "0" "$(ls "$OUT2"/*.md 2>/dev/null | wc -l | tr -d ' ')"
  eq "不合格的原始輸出留底" "1" "$(ls "$OUT2/_rejected"/*.md 2>/dev/null | wc -l | tr -d ' ')"
}

test_summary_counts() {
  local out
  out="$(run_extract "$IN/nestjs-clusters.jsonl" "$OUT3" "$STUB/agent" 2>&1)"
  has "印出產出數" "$out" "產出 1"
  has "印出丟棄數" "$out" "丟棄 1"
}

# =============================================================================
# 案例 6-15：自己構造的畸形/邊界輸入
# =============================================================================

# agent 吐空字串（exit 0，但沒有任何內容）：沒有 id 欄位，走 REJECTED 路徑，
# 不應該當成崩潰處理，也不該落地成規則檔。
test_agent_returns_empty_string() {
  cat > "$STUB/empty-agent" <<'SH'
#!/usr/bin/env bash
cat >/dev/null
printf ''
SH
  chmod +x "$STUB/empty-agent"
  local out out_dir="$TMP/out-empty"
  mkdir -p "$out_dir"
  out="$(run_extract "$IN/nestjs-clusters.jsonl" "$out_dir" "$STUB/empty-agent" 2>&1)"
  has "空字串輸出被記為 RULE_REJECTED" "$out" "RULE_REJECTED"
  eq "空字串輸出不落地成規則檔" "0" "$(ls "$out_dir"/*.md 2>/dev/null | wc -l | tr -d ' ')"
}

# agent 吐合法 JSON，但不是規則檔（沒有 frontmatter）：一樣要被 rule_field 判定
# 缺 id、走 REJECTED 路徑，而不是被當成某種「半成功」誤判。
test_agent_returns_valid_json_but_not_a_rule_file() {
  cat > "$STUB/json-agent" <<'SH'
#!/usr/bin/env bash
cat >/dev/null
printf '{"not":"a rule file","just":"json"}\n'
SH
  chmod +x "$STUB/json-agent"
  local out out_dir="$TMP/out-json"
  mkdir -p "$out_dir"
  out="$(run_extract "$IN/nestjs-clusters.jsonl" "$out_dir" "$STUB/json-agent" 2>&1)"
  has "合法 JSON 但非規則檔一樣被 RULE_REJECTED" "$out" "RULE_REJECTED"
  eq "不落地成規則檔" "0" "$(ls "$out_dir"/*.md 2>/dev/null | wc -l | tr -d ' ')"
}

# agent 指令本身以非 0 退出（模擬額度用盡、認證失效、崩潰等）：這跟前兩個
# 案例不同——前兩個是「agent 有輸出，但輸出的內容不合格」，這個是「agent
# 根本沒有輸出可言」。沒有 raw 產出，_rejected/ 不該多出任何檔案；這個失敗
# 也不該混進「退回（驗證不過）」的數字，因為它根本沒機會被驗證——要有自己
# 的持久記錄（_agent_failed.tsv）跟自己的 summary 計數。
test_agent_command_failure_is_recorded_separately() {
  cat > "$STUB/failing-agent" <<'SH'
#!/usr/bin/env bash
cat >/dev/null
echo "模擬 agent 額度用盡或崩潰" >&2
exit 17
SH
  chmod +x "$STUB/failing-agent"
  local out_dir="$TMP/out-agent-failed" out
  mkdir -p "$out_dir"
  out="$(run_extract "$IN/nestjs-clusters.jsonl" "$out_dir" "$STUB/failing-agent" 2>&1)"

  eq "agent 失敗不落地成任何規則檔" "0" "$(ls "$out_dir"/*.md 2>/dev/null | wc -l | tr -d ' ')"
  eq "agent 失敗不留底到 _rejected（沒有 raw 產出可以留底）" "0" \
    "$(ls "$out_dir/_rejected"/*.md 2>/dev/null | wc -l | tr -d ' ')"

  has "stderr 印出 AGENT_FAILED" "$out" "AGENT_FAILED"
  has "stderr 印出 agent 的退出碼" "$out" "exit=17"

  eq "_agent_failed.tsv 恰好一筆（另一群出處不足，走的是丟棄，不是 agent 失敗）" \
    "1" "$(grep -c . "$out_dir/_agent_failed.tsv")"
  has "_agent_failed.tsv 記到來源檔案的 tag" "$(cat "$out_dir/_agent_failed.tsv")" "nestjs-clusters"
  has "_agent_failed.tsv 記到 top_terms" "$(cat "$out_dir/_agent_failed.tsv")" "scope"
  has "_agent_failed.tsv 記到 agent 的退出碼" "$(cat "$out_dir/_agent_failed.tsv")" "17"

  has "summary 分開報 agent 失敗" "$out" "agent 失敗 1"
  has "summary 的「退回（驗證不過）」沒有把 agent 失敗混進去" "$out" "退回 0（驗證不過）"
}

# 兩個不同的群，agent 都吐出同一個 id：第一個成功落地，第二個不該悄悄覆蓋
# 掉第一個檔案——那是把一條已經驗證過的規則靜默銷毀。第二個要被記為
# RULE_REJECTED，且第一個檔案的內容要維持原樣。
test_duplicate_id_from_different_clusters_does_not_overwrite() {
  # 兩個群都吐出同一個 id，但出處章節照各自輸入的 members 產生——內容真的
  # 不同，不是巧合相同。這樣「既有檔案沒被覆蓋」這個斷言才有辨別力：如果
  # 兩群輸出剛好長得一樣，靜默覆蓋跟正確保留在斷言層面會無法區分。
  cat > "$STUB/collide-agent" <<'SH'
#!/usr/bin/env bash
input="$(cat)"
cat <<MD
---
id: nestjs-collide
layer: nestjs
frameworks: ["@nestjs/core@>=9"]
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

  printf '%s\n' \
    '{"cluster":0,"n":3,"top_terms":["a"],"members":[{"html_url":"https://x/a"},{"html_url":"https://x/b"},{"html_url":"https://x/c"}]}' \
    '{"cluster":1,"n":3,"top_terms":["b"],"members":[{"html_url":"https://x/d"},{"html_url":"https://x/e"},{"html_url":"https://x/f"}]}' \
    > "$IN/collide-clusters.jsonl"

  local out_dir="$TMP/out-collide" out
  mkdir -p "$out_dir"
  out="$(run_extract "$IN/collide-clusters.jsonl" "$out_dir" "$STUB/collide-agent" 2>&1)"
  eq "撞名時只有一個檔案落地" "1" "$(ls "$out_dir"/*.md 2>/dev/null | wc -l | tr -d ' ')"
  has "撞名的第二個群被記為 RULE_REJECTED" "$out" "RULE_REJECTED"
  has "訊息指名是撞名" "$out" "撞名"
  has "既有檔案的出處沒被覆蓋（仍是第一個群的 a/b/c）" \
    "$(cat "$out_dir/nestjs-collide.md")" "https://x/a"
  lacks "既有檔案沒被第二個群的內容（d/e/f）取代" \
    "$(cat "$out_dir/nestjs-collide.md")" "https://x/d"
}

# cluster 檔有一行壞掉（不是合法 JSON），夾在兩個合法群中間：應該指名是哪個
# 檔第幾行壞的，退出碼非 0，不能悄悄跳過或吞掉、也不能繼續拿壞資料往下跑。
test_malformed_cluster_line_fails_loudly() {
  printf '%s\n' \
    '{"cluster":0,"n":3,"top_terms":["a"],"members":[{"html_url":"https://x/g"},{"html_url":"https://x/h"},{"html_url":"https://x/i"}]}' \
    'this is not json at all {{{' \
    '{"cluster":2,"n":3,"top_terms":["b"],"members":[{"html_url":"https://x/j"},{"html_url":"https://x/k"},{"html_url":"https://x/l"}]}' \
    > "$IN/broken-clusters.jsonl"

  local out_dir="$TMP/out-broken" out rc
  mkdir -p "$out_dir"
  out="$(run_extract "$IN/broken-clusters.jsonl" "$out_dir" "$STUB/agent" 2>&1)"; rc=$?
  [ "$rc" -ne 0 ] && ok "壞掉的群組行退出碼非 0" || fail "應退出非 0"
  has "印出 CLUSTER_LINE_INVALID" "$out" "CLUSTER_LINE_INVALID"
  has "指名是哪個檔壞的" "$out" "broken-clusters.jsonl"
  has "指名第幾行壞的" "$out" "第 2 行"
}

# members 是空陣列：unique 後長度是 0，應該落在「出處不足」被丟棄，不呼叫
# agent、不當成任何一種例外。
test_empty_members_array_is_dropped() {
  printf '%s\n' \
    '{"cluster":0,"n":0,"top_terms":["x"],"members":[]}' \
    > "$IN/empty-members.jsonl"
  local out_dir="$TMP/out-empty-members" out
  mkdir -p "$out_dir"
  out="$(run_extract "$IN/empty-members.jsonl" "$out_dir" "$STUB/agent" 2>&1)"
  has "印出丟棄 1" "$out" "丟棄 1"
  eq "沒有產出任何規則檔" "0" "$(ls "$out_dir"/*.md 2>/dev/null | wc -l | tr -d ' ')"
  has "丟棄記錄裡出處是 0 則" "$(cat "$out_dir/_dropped.tsv")" "出處只有 0 則"
}

# html_url 全部是 null：unique 後這些 null 只算一個「不重複值」，nsrc=1，
# 撐不起下限 3，應該被丟棄——這確保「不重複出處」是真的算「不重複來源」，
# 不是單純數 members 筆數（5 則全 null 不該被誤判成 5 則出處）。
test_all_null_html_url_counts_as_one_source_and_is_dropped() {
  printf '%s\n' \
    '{"cluster":0,"n":5,"top_terms":["x"],"members":[{"html_url":null},{"html_url":null},{"html_url":null},{"html_url":null},{"html_url":null}]}' \
    > "$IN/null-urls.jsonl"
  local out_dir="$TMP/out-null-urls" out
  mkdir -p "$out_dir"
  out="$(run_extract "$IN/null-urls.jsonl" "$out_dir" "$STUB/agent" 2>&1)"
  has "印出丟棄 1" "$out" "丟棄 1"
  eq "沒有產出任何規則檔" "0" "$(ls "$out_dir"/*.md 2>/dev/null | wc -l | tr -d ' ')"
  has "丟棄記錄裡出處只有 1 則（null 只算一個不重複值）" \
    "$(cat "$out_dir/_dropped.tsv")" "出處只有 1 則"
}

# agent 吐出的 id 帶路徑分隔字元（企圖跳脫 $OUT 目錄）：不該被拿去當 mv 的
# 目的地路徑，要在寫檔之前就攔下來，也不該在 $OUT 之外留下任何東西。
test_unsafe_id_with_path_separator_is_rejected() {
  cat > "$STUB/traversal-agent" <<'SH'
#!/usr/bin/env bash
cat >/dev/null
cat <<MD
---
id: ../../../tmp/mra-path-traversal-probe
layer: nestjs
frameworks: ["@nestjs/core@>=9"]
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
  rm -f /tmp/mra-path-traversal-probe.md
  local out_dir="$TMP/out-traversal" out
  mkdir -p "$out_dir"
  out="$(run_extract "$IN/nestjs-clusters.jsonl" "$out_dir" "$STUB/traversal-agent" 2>&1)"
  has "含路徑分隔字元的 id 被 RULE_REJECTED" "$out" "RULE_REJECTED"
  eq "沒有寫到 \$OUT 目錄之外" "0" "$([ -f /tmp/mra-path-traversal-probe.md ] && echo 1 || echo 0)"
  eq "\$OUT 目錄裡沒有產出規則檔" "0" "$(find "$out_dir" -maxdepth 1 -name '*.md' | wc -l | tr -d ' ')"
  rm -f /tmp/mra-path-traversal-probe.md
}

# 對同一個 --out 目錄跑兩次（模擬 Step 6 對五層各呼叫一次）：_dropped.tsv
# 若每次呼叫都截斷重寫，第二次跑完只會剩第二次的紀錄，第一次的丟棄清單會
# 被悄悄蓋掉。兩次都要留在檔案裡。
test_dropped_log_accumulates_across_layers_sharing_out_dir() {
  local out_dir="$TMP/out-shared"
  mkdir -p "$out_dir"
  printf '%s\n' \
    '{"cluster":0,"n":1,"top_terms":["layerA"],"members":[{"html_url":"https://x/a1"}]}' \
    > "$IN/layerA-clusters.jsonl"
  printf '%s\n' \
    '{"cluster":0,"n":1,"top_terms":["layerB"],"members":[{"html_url":"https://x/b1"}]}' \
    > "$IN/layerB-clusters.jsonl"
  run_extract "$IN/layerA-clusters.jsonl" "$out_dir" "$STUB/agent" >/dev/null 2>&1
  run_extract "$IN/layerB-clusters.jsonl" "$out_dir" "$STUB/agent" >/dev/null 2>&1
  has "第一層的丟棄紀錄還在" "$(cat "$out_dir/_dropped.tsv")" "layerA"
  has "第二層的丟棄紀錄也在" "$(cat "$out_dir/_dropped.tsv")" "layerB"
}

# 兩層的群 id 都重新從 0 起算，且兩層跑的都是會被拒絕的產出：_rejected/ 底下
# 的檔名如果只用裸的 cluster id，兩層的 cluster 0 會互相覆蓋掉對方的診斷檔。
test_rejected_filenames_do_not_collide_across_layers() {
  local out_dir="$TMP/out-rejected-collide"
  mkdir -p "$out_dir"
  printf '%s\n' \
    '{"cluster":0,"n":3,"top_terms":["a"],"members":[{"html_url":"https://x/ra1"},{"html_url":"https://x/ra2"},{"html_url":"https://x/ra3"}]}' \
    > "$IN/rlayerA-clusters.jsonl"
  printf '%s\n' \
    '{"cluster":0,"n":3,"top_terms":["b"],"members":[{"html_url":"https://x/rb1"},{"html_url":"https://x/rb2"},{"html_url":"https://x/rb3"}]}' \
    > "$IN/rlayerB-clusters.jsonl"
  run_extract "$IN/rlayerA-clusters.jsonl" "$out_dir" "$STUB/bad-agent" >/dev/null 2>&1
  run_extract "$IN/rlayerB-clusters.jsonl" "$out_dir" "$STUB/bad-agent" >/dev/null 2>&1
  eq "兩層各自留下一個 _rejected 診斷檔，互不覆蓋" "2" \
    "$(ls "$out_dir/_rejected"/*.md 2>/dev/null | wc -l | tr -d ' ')"
}

test_drops_clusters_with_too_few_sources
test_dropped_log_names_the_topic
test_output_passes_validation
test_invalid_agent_output_is_rejected
test_summary_counts
test_agent_returns_empty_string
test_agent_returns_valid_json_but_not_a_rule_file
test_agent_command_failure_is_recorded_separately
test_duplicate_id_from_different_clusters_does_not_overwrite
test_malformed_cluster_line_fails_loudly
test_empty_members_array_is_dropped
test_all_null_html_url_counts_as_one_source_and_is_dropped
test_unsafe_id_with_path_separator_is_rejected
test_dropped_log_accumulates_across_layers_sharing_out_dir
test_rejected_filenames_do_not_collide_across_layers

echo "---"; echo "Passed: $pass"; echo "Failed: $errors"
exit $((errors > 0 ? 1 : 0))
