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
  # 原本這裡的 needle 是單一字元 "1"。_dropped.tsv 只要有任何一列、裡面帶著
  # 群大小或出處數，幾乎不可能不含 "1"，所以那個斷言連「有沒有記到正確的
  # 那一群」都分不出來。改成比對整列的欄位形狀：tag、cluster id、n、
  # top_terms、丟棄原因，五個欄位錯一個就紅。
  eq "_dropped.tsv 恰好一列（只有出處不足的那一群）" "1" "$(grep -c . "$OUT/_dropped.tsv")"
  eq "丟棄記錄的欄位形狀完整（tag、cluster id、n、top_terms、原因）" \
    "$(printf 'nestjs-clusters\t1\t2\ttest\t出處只有 2 則')" "$(cat "$OUT/_dropped.tsv")"
}

test_dropped_log_names_the_topic() {
  has "丟棄記錄含 top_terms" "$(cat "$OUT/_dropped.tsv")" "test"
}

test_output_passes_validation() {
  # 原本是迴圈跑完無條件 ok()：迴圈裡已經 fail() 過也照樣多印一行 PASS，而且
  # 一個檔案都沒產出（迴圈跑零次）時這個測試是純綠的，等於什麼都沒驗到。
  # 改成分別斷言「確實有東西可驗」與「驗過的全部通過」。
  local f checked=0 bad=0
  for f in "$OUT"/*.md; do
    [ -e "$f" ] || continue
    checked=$((checked + 1))
    rule_validate "$f" || bad=$((bad + 1))
  done
  eq "確實有規則檔可驗（迴圈跑零次的話這個測試沒驗到東西）" "1" "$checked"
  eq "所有產出都通過 rule_validate" "0" "$bad"
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

# agent 吐空字串（exit 0，但沒有任何內容）：這跟「吐出來了但格式不合格」是
# 兩種不同的失敗，要分開報。原本兩者都走 RULE_REJECTED，於是空輸出會得到一句
# 「沒通過驗證」（根本沒有東西可驗，這句話是錯的）跟一個 1 byte 的 _rejected
# 檔（_rejected/ 的用途是留住原始產出供人判斷是 prompt 還是模型的問題，1 byte
# 的檔案兩者都判斷不了），還把「退回 K（驗證不過）」這個數字灌水。
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
  has "空輸出用自己的 token 報" "$out" "AGENT_EMPTY_OUTPUT"
  lacks "空輸出不報成 RULE_REJECTED（它根本沒有東西可以驗）" "$out" "RULE_REJECTED"
  eq "空字串輸出不落地成規則檔" "0" "$(ls "$out_dir"/*.md 2>/dev/null | wc -l | tr -d ' ')"
  eq "空輸出不留下 1 byte 的 _rejected 診斷檔" "0" \
    "$(ls "$out_dir/_rejected"/*.md 2>/dev/null | wc -l | tr -d ' ')"
  has "空輸出記進 _agent_failed.tsv（它是呼叫失敗，不是資料不夠格）" \
    "$(cat "$out_dir/_agent_failed.tsv")" "agent 空輸出（退出碼 0）"
  has "summary 用自己的數字報空輸出" "$out" "agent 空輸出 1"
  has "summary 的「退回（驗證不過）」沒有把空輸出混進去" "$out" "退回 0（驗證不過）"
  has "summary 的「agent 失敗」也沒有把空輸出混進去" "$out" "agent 失敗 0"
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

# 對同一個 --out 目錄重跑「同一層」：那一層的舊列要被換掉，不是再疊一份。
# 原本兩份 .tsv 都是無條件 append，同一層跑第二次會讓同一批列出現兩次（實測
# 6 列變 12 列），而同一個目錄裡的 _rejected/<tag>-<cid>.md 走的卻是覆蓋，
# 一個目錄裡並存兩種相反的語意。選定的語意是「以來源 tag 為單位，最後一次跑
# 覆蓋前一次」，所以這裡同時驗兩件事：重跑不會讓自己那一層變兩份，也不會把
# 別層的列連帶掃掉。
test_rerun_of_one_layer_replaces_only_that_layers_rows() {
  local out_dir="$TMP/out-rerun"
  mkdir -p "$out_dir"
  # 自己建 stub，不借用別的測試建好的那支：測試之間不該有隱性的執行順序相依。
  cat > "$STUB/rerun-failing-agent" <<'SH'
#!/usr/bin/env bash
cat >/dev/null
exit 17
SH
  chmod +x "$STUB/rerun-failing-agent"
  # 每個檔都是「一群夠格（會呼叫 agent，agent 失敗）＋一群出處不足（丟棄）」，
  # 這樣一次呼叫同時在兩份 .tsv 各留下一列。
  printf '%s\n' \
    '{"cluster":0,"n":3,"top_terms":["rrA"],"members":[{"html_url":"https://x/ra"},{"html_url":"https://x/rb"},{"html_url":"https://x/rc"}]}' \
    '{"cluster":1,"n":1,"top_terms":["rrAdrop"],"members":[{"html_url":"https://x/rd"}]}' \
    > "$IN/rerunA-clusters.jsonl"
  printf '%s\n' \
    '{"cluster":0,"n":3,"top_terms":["rrB"],"members":[{"html_url":"https://x/re"},{"html_url":"https://x/rf"},{"html_url":"https://x/rg"}]}' \
    '{"cluster":1,"n":1,"top_terms":["rrBdrop"],"members":[{"html_url":"https://x/rh"}]}' \
    > "$IN/rerunB-clusters.jsonl"

  run_extract "$IN/rerunA-clusters.jsonl" "$out_dir" "$STUB/rerun-failing-agent" >/dev/null 2>&1
  run_extract "$IN/rerunB-clusters.jsonl" "$out_dir" "$STUB/rerun-failing-agent" >/dev/null 2>&1
  eq "兩層各跑一次後 _dropped.tsv 有兩列" "2" "$(grep -c . "$out_dir/_dropped.tsv")"
  eq "兩層各跑一次後 _agent_failed.tsv 有兩列" "2" "$(grep -c . "$out_dir/_agent_failed.tsv")"

  # 只重跑 layerA。
  run_extract "$IN/rerunA-clusters.jsonl" "$out_dir" "$STUB/rerun-failing-agent" >/dev/null 2>&1
  eq "重跑同一層之後 _dropped.tsv 仍然是兩列，不是三列" "2" \
    "$(grep -c . "$out_dir/_dropped.tsv")"
  eq "重跑同一層之後 _agent_failed.tsv 仍然是兩列，不是三列" "2" \
    "$(grep -c . "$out_dir/_agent_failed.tsv")"
  eq "重跑的那一層在 _dropped.tsv 只留一列" "1" \
    "$(grep -c 'rerunA-clusters' "$out_dir/_dropped.tsv")"
  eq "重跑的那一層在 _agent_failed.tsv 只留一列" "1" \
    "$(grep -c 'rerunA-clusters' "$out_dir/_agent_failed.tsv")"
  eq "沒被重跑的那一層在 _dropped.tsv 還在" "1" \
    "$(grep -c 'rerunB-clusters' "$out_dir/_dropped.tsv")"
  eq "沒被重跑的那一層在 _agent_failed.tsv 還在" "1" \
    "$(grep -c 'rerunB-clusters' "$out_dir/_agent_failed.tsv")"
}

# 目的地必須用原子的方式宣告。「先 [ -e ] 檢查、再 mv」在多個行程共用同一個
# --out 目錄時兩個都會通過檢查，後到的 mv 靜默覆蓋先到的那個，也就是那段檢查
# 本來要防的事照樣發生。真的去跑一個競態來驗會是不穩定的測試（要剛好卡進
# 檢查與 mv 之間那幾微秒），所以這裡改成把「宣告方式」本身鎖住：用 noclobber
# 的 O_EXCL 建檔，且不留下舊的 check-then-move 形狀。
test_dest_is_claimed_atomically_not_check_then_move() {
  local f="$MRA_DIR/scripts/extract-rules-tfidf.sh" src
  src="$(cat "$f")"
  has "用 noclobber 的 O_EXCL 建檔宣告目的地" "$src" "set -o noclobber"
  has "宣告失敗時區分得出是撞名還是寫入出錯" "$src" "DEST_CLAIM_FAILED"
  # 宣告一定要發生在 mv 之前才有意義。只驗「檔案裡有 noclobber 這個字」的話，
  # 它出現在註解裡或出現在 mv 之後都會過。
  local claim_ln mv_ln
  claim_ln="$(grep -n 'set -o noclobber' "$f" | head -1 | cut -d: -f1)"
  mv_ln="$(grep -n 'mv "\$tmp" "\$dest"' "$f" | head -1 | cut -d: -f1)"
  if [ -n "$claim_ln" ] && [ -n "$mv_ln" ] && [ "$claim_ln" -lt "$mv_ln" ]; then
    ok "目的地在 mv 之前就被原子地宣告掉"
  else
    fail "目的地沒有在 mv 之前被宣告（claim 在第 ${claim_ln:-無} 行、mv 在第 ${mv_ln:-無} 行）"
  fi
}

# =============================================================================
# scripts/rule-agent.sh：這支腳本是上面兩條萃取路線預設的 MRA_RULE_AGENT_CMD
# （見 plan 的 Step 6／Step 7 驅動迴圈），所以它的失敗行為就是這條管線的失敗
# 行為，測試放在這裡而不是另開一支檔案。
#
# 它原本直接呼叫 claude，沒有任何重試：API 暫時性失敗（overloaded、5xx）會讓
# 那一群直接記成 agent 失敗，而整條管線跑一次要幾小時、燒掉大量額度，重跑的
# 代價非常高。也沒有空輸出偵測：claude 退出 0 卻沒吐東西時，呼叫端拿到的是
# 空字串。
#
# 不共用 lib/claude-invoke.sh 的 claude_invoke，是因為它沒辦法重放 stdin：
# 它的重試迴圈在同一個行程裡重跑同一組 argv，繼承下來的 stdin 位移是共用的，
# 第一次嘗試讀完就停在 EOF。下面第一個測試就是在盯這件事：每一次嘗試都要拿到
# 完整的 prompt，不能第二次變成空的。prompt 走 stdin 是硬需求（rails 層的大群
# 塞進 argv 會撞 ARG_MAX），所以只能自己寫迴圈。
# =============================================================================

# 建一支假的 claude：行為由 $MODE 決定，每次呼叫把「這次收到幾 bytes 的 stdin」
# 記進 log，讓測試驗得到重試時 prompt 有沒有被重放。
write_fake_claude() {
  cat > "$STUB/fake-claude" <<'SH'
#!/usr/bin/env bash
n=$(cat "$FC_COUNT"); n=$((n + 1)); echo "$n" > "$FC_COUNT"
seen="$(cat)"
echo "attempt=${n} bytes=${#seen}" >> "$FC_COUNT.log"
case "$FC_MODE" in
  transient) if [ "$n" -le 2 ]; then echo "API Error: Overloaded (529)" >&2; exit 1; fi
             printf 'RULE-BODY\n' ;;
  empty)     printf '' ;;
  fatal)     echo "error: unknown option --bogus" >&2; exit 1 ;;
  *)         printf 'RULE-BODY\n' ;;
esac
SH
  chmod +x "$STUB/fake-claude"
}
write_fake_claude

# $1=MODE，回傳 "rc|stdout|呼叫次數"，並把每次嘗試的 stdin 位元組數留在
# $TMP/fc.log 供斷言。
run_rule_agent() {
  local mode="$1" out rc
  echo 0 > "$TMP/fc"
  : > "$TMP/fc.log"
  out="$(printf '{"cluster":0,"n":3,"top_terms":["x"],"members":[]}' \
    | FC_COUNT="$TMP/fc" FC_MODE="$mode" \
      MRA_CLAUDE_BIN="$STUB/fake-claude" \
      MRA_CLAUDE_RETRY_DELAY=0 MRA_CLAUDE_MAX_RETRIES=2 \
      bash "$MRA_DIR/scripts/rule-agent.sh" 2>"$TMP/fc.err")"
  rc=$?
  cp "$TMP/fc.log" "$TMP/fc-last.log"
  printf '%s|%s|%s' "$rc" "$out" "$(cat "$TMP/fc")"
}

# 暫時性失敗要重試，而且每一次嘗試都要拿到完整的 prompt。第二個斷言是這整組
# 測試的重點：直接共用 claude_invoke 的話，重試那次的 stdin 會是 0 bytes，
# 等於拿空 prompt 去問模型再把結果當成規則，比不重試更糟。
test_rule_agent_retries_transient_failure_with_prompt_intact() {
  local r; r="$(run_rule_agent transient)"
  eq "暫時性失敗重試後成功（退出碼 0）" "0" "${r%%|*}"
  has "重試成功後照樣把模型輸出交給呼叫端" "$r" "RULE-BODY"
  eq "重試到第 3 次才成功（前兩次是 529）" "3" "${r##*|}"
  eq "每一次嘗試都拿到完整的 prompt，重試那次不是空的" "0" \
    "$(grep -c 'bytes=0' "$TMP/fc-last.log")"
  eq "確實嘗試了 3 次（log 有三列）" "3" "$(grep -c . "$TMP/fc-last.log")"
}

# 退出 0 但空輸出也算暫時性失敗，要重試；重試用完仍然是空的話不能跟著回 0，
# 否則呼叫端會把空字串當成一份產出往下送驗證。
test_rule_agent_retries_empty_output_then_fails_loudly() {
  local r; r="$(run_rule_agent empty)"
  eq "重試用完仍是空輸出時不回 0" "65" "${r%%|*}"
  eq "空輸出有重試（1 次原本 + 2 次重試）" "3" "${r##*|}"
  has "用可以 grep 的 token 報空輸出" "$(cat "$TMP/fc.err")" "RULE_AGENT_EMPTY_OUTPUT"
}

# 非暫時性的失敗（例如打錯旗標）不該重試：那只是把同一個必然的失敗再燒兩次
# 額度。stderr 也一定要交出去，不能吞掉。
test_rule_agent_does_not_retry_fatal_error() {
  local r; r="$(run_rule_agent fatal)"
  eq "非暫時性失敗只呼叫一次，不重試" "1" "${r##*|}"
  eq "退出碼原樣往上傳" "1" "${r%%|*}"
  has "claude 的 stderr 有交出去，不是吞掉" "$(cat "$TMP/fc.err")" "unknown option --bogus"
}

# 重試的進度訊息必須走 stderr。log_warn 預設印到 stdout，而這支腳本的 stdout
# 會被呼叫端整段捕成規則內容，一行進度訊息混進去就變成規則檔的一部分。
test_rule_agent_progress_messages_never_pollute_stdout() {
  local r; r="$(run_rule_agent transient)"
  local body="${r#*|}"; body="${body%|*}"
  eq "stdout 只有模型輸出，沒有重試訊息" "RULE-BODY" "$body"
  has "重試訊息在 stderr" "$(cat "$TMP/fc.err")" "暫時性失敗"
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
test_rerun_of_one_layer_replaces_only_that_layers_rows
test_dest_is_claimed_atomically_not_check_then_move
test_rule_agent_retries_transient_failure_with_prompt_intact
test_rule_agent_retries_empty_output_then_fails_loudly
test_rule_agent_does_not_retry_fatal_error
test_rule_agent_progress_messages_never_pollute_stdout


# --- 旗標缺值時的訊息要指得到使用者打錯的東西 -----------------------------
# 少了 arity 檢查的話會踩到 set -u，訊息是「$2: 未綁定的變數」，跟使用者打錯
# 的東西完全對不上。這支腳本跑一次要幾小時、燒掉大量 API 額度，開場就給一句
# 看不懂的話最糟。
ARITY_IN="$TMP/arity-input.jsonl"
printf '%s\n' '{"layer":"common","cluster_id":1,"size":3,"top_terms":["a"],"members":[]}' > "$ARITY_IN"
for _flag in --clusters --out; do
  arity_out="$(bash "$MRA_DIR/scripts/extract-rules-tfidf.sh" "$_flag" 2>&1)"
  has "旗標 $_flag 缺值時的訊息指名它自己" "$arity_out" "$_flag"
  lacks "旗標 $_flag 缺值時不是 set -u 的原始錯誤" "$arity_out" "未綁定"
  lacks "旗標 $_flag 缺值時不是英文的 unbound variable" "$arity_out" "unbound variable"
done

# --out 整個沒給時 OUT 是空字串，mkdir 的訊息會是「mkdir: : No such file or
# directory」，同樣跟輸入無關。
out_missing="$(bash "$MRA_DIR/scripts/extract-rules-tfidf.sh" --clusters "$ARITY_IN" 2>&1)"
has "缺 --out 時用 OUT_MISSING 這個 token" "$out_missing" "OUT_MISSING"
lacks "缺 --out 時不是 mkdir 的原始錯誤" "$out_missing" "mkdir"

echo "---"; echo "Passed: $pass"; echo "Failed: $errors"
exit $((errors > 0 ? 1 : 0))
