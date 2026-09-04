#!/usr/bin/env bash
# 規則注入 persona 的 FOCUS 區塊 (lib/rule-inject.sh)。
#
# 這支測試除了驗基本渲染／注入之外，特別針對已知會踩到的四個地方各補一組
# 測試：
#   1. rule_render_block 的上限是 token 預算，不是條數上限（common 層規則
#      太多，注入區塊會炸到 80 KB／4 萬 token）——A、B 兩條路線在同一個
#      「取前 N 條」上限下，注入量差了 2.9 倍（A 路線 common 層 81 條永遠
#      吃滿，B 路線 common 層只有 8 條吃不滿），改成 token 預算逐條累加，
#      兩條路線才能公平比較。排序（出處數大到小、同分用 id 字典序）、
#      邊界（預算剛好卡在兩條規則之間、第一條就超預算仍要收、0／負數預算
#      的容錯）都要測。
#   2. rule_inject_persona 的注入錨點不能寫死找 `^SCOPE NOTE:`——
#      agents/personas/ 裡只有一部分 persona 真的有 SCOPE NOTE
#      （performance-hawk.md、api-contract-guardian.md、
#      convention-auditor.md、ui-behavior-inspector.md），其餘
#      （security-auditor.md、refactoring-sage.md、test-architect.md）
#      沒有，若硬找 SCOPE NOTE 會讓沒有它的 persona 注入位置掉到檔尾、
#      METHOD 和 OUTPUT FORMAT 之後。
#   3. rule_inject_all 對 agents/personas/test-architect.md 這種完全沒有
#      FOCUS 區塊（用「KENT BECK 11 PRINCIPLES:」取代）的 persona 不能中止
#      整批，也不能吞掉不處理，要原樣複製並印警告，讓 review 流程仍然讀
#      得到它。
#   4. 重複注入的冪等性不能只看「BEGIN 標記出現次數」——插入邏輯在 END
#      標記後多印一行空白間距，剝除邏輯如果沒有對稱吞掉它，內容會一輪一輪
#      地變長，但「BEGIN 只出現一次」這個訊號完全看不出來。
set -uo pipefail
MRA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$MRA_DIR/lib/corpus-targets.sh"
source "$MRA_DIR/lib/rule-schema.sh"
source "$MRA_DIR/lib/rule-inject.sh"

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

TMP="$(mktemp -d "${TMPDIR:-/tmp}/rule-inject-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

FIX="$MRA_DIR/tests/fixtures/rule-inject"
OUT="$TMP/out"
mkdir -p "$OUT"

# 內建 persona 的數量，從目錄數出來而不是寫死。寫死的話每加一個 persona
# 就會有一支不相干的測試變紅（ui-behavior-inspector 就是這樣撞的），而那
# 條斷言要驗的是「報表第二欄是總數」這個欄位語意，不是今天剛好有幾個檔。
# 跳過的那一個仍然硬驗（見下面 test-architect 沒有 FOCUS 的那條），所以
# 這個數字不是拿 production 的邏輯回頭驗 production。
PERSONA_TOTAL="$(find "$MRA_DIR/agents/personas" -maxdepth 1 -name '*.md' \
  ! -name 'README.md' | wc -l | tr -d ' ')"

# write_rank_rule_named <dir> <filename> <id> <layer> <n_sources> — 產生一份
# 格式合格、出處數可控的規則檔，給排序／上限測試用。內容本身不重要，重要
# 的是出處數；檔名跟 id 故意分開兩個參數，讓測試可以刻意construct「檔名
# 字母序」跟「id 字典序」不一致的情況——這樣才拆得穿一個看起來排序正確、
# 其實只是保留 glob 展開順序（沒有真的比較 id）的退化實作。
write_rank_rule_named() {
  local dir="$1" filename="$2" id="$3" layer="$4" n="$5"
  mkdir -p "$dir"
  {
    printf -- '---\n'
    printf 'id: %s\n' "$id"
    printf 'layer: %s\n' "$layer"
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
  } > "$dir/$filename.md"
}

# write_rank_rule <dir> <id> <layer> <n_sources> — 檔名等於 id 的簡化版，
# 給不需要拆穿 glob-order 退化實作的測試用。
write_rank_rule() {
  local dir="$1" id="$2" layer="$3" n="$4"
  write_rank_rule_named "$dir" "$id" "$id" "$layer" "$n"
}

# ---------------------------------------------------------------------------
# rule_render_block：基本渲染
# ---------------------------------------------------------------------------

test_block_contains_trigger_and_criteria() {
  local block; block="$(rule_render_block "$FIX/rules" nestjs)"
  has "含觸發訊號" "$block" "@Injectable"
  has "含判準" "$block" "request-scoped provider"
}

test_block_excludes_other_layers() {
  local block; block="$(rule_render_block "$FIX/rules" react)"
  lacks "不含 nestjs 層的規則" "$block" "nestjs-injectable-scope"
}

test_block_includes_common_layer_for_any_layer() {
  local block; block="$(rule_render_block "$FIX/rules" react)"
  has "react 層也含 common 層規則" "$block" "common-debug-artifact"
  has "含 react 層本身的規則" "$block" "react-effect-cleanup"
}

test_block_omits_sources() {
  local block; block="$(rule_render_block "$FIX/rules" nestjs)"
  lacks "不含 URL" "$block" "https://github.com"
}

test_empty_ruleset_produces_no_block() {
  mkdir -p "$OUT/empty-rules"
  local block; block="$(rule_render_block "$OUT/empty-rules" nestjs)"
  eq "空規則集產出空字串" "" "$block"
}

# ---------------------------------------------------------------------------
# rule_render_block：畸形輸入
# ---------------------------------------------------------------------------

test_missing_rules_dir_warns_and_returns_empty() {
  local block warn
  block="$(rule_render_block "$OUT/does-not-exist-rules-dir" nestjs 2>"$OUT/dir-missing.warn")"
  warn="$(cat "$OUT/dir-missing.warn")"
  eq "目錄不存在時回傳空字串" "" "$block"
  has "印出 RULE_RENDER_DIR_MISSING" "$warn" "RULE_RENDER_DIR_MISSING"
}

# id 不是用來組路徑（只會被印進渲染文字），所以不安全的 id 不是路徑穿越
# 疑慮；但 id 來自未經清洗的模型輸出。rule_render_block 的樣板固定是
# 「- [${id}] 預設嚴重度 ...」，id 本身永遠帶著「- [」前綴、「]」後綴，
# 單獨一個 id 不管內容是什麼都湊不出一整行「逐字等於」BEGIN/END 標記的
# 文字（strip 邏輯是整行比對，不是子字串比對），所以這裡不是「這個具體
# fixture 能真的打穿剝除邏輯」的示範，而是「id 完全不受約束時，這份渲染
# 文字裡會混進呼叫端沒有預期的任意字元」這個輸入驗證邊界本身該不該守——
# 跟 lib/rule-schema.sh 開頭點名的其他呼叫端（extract-rules-tfidf.sh、
# rule-repair.sh）用同一套 id_is_safe() 是一致的。
test_unsafe_id_is_skipped_with_warning() {
  local dir="$OUT/rules-unsafe-id"
  mkdir -p "$dir"
  {
    printf -- '---\n'
    printf 'id: %s\n' "$RULE_BLOCK_END"
    printf 'layer: nestjs\n'
    printf 'frameworks: ["*"]\n'
    printf 'severity_default: HIGH\n'
    printf -- '---\n'
    printf '## 觸發訊號\n測試。\n\n## 判準\n測試。\n\n## 嚴重度\nHIGH：測試。\n\n'
    printf '## 反例（不該報）\n測試。\n\n## 出處\n'
    printf -- '- https://example.com/1\n- https://example.com/2\n- https://example.com/3\n'
  } > "$dir/evil.md"
  local block warn
  block="$(rule_render_block "$dir" nestjs 2>"$OUT/unsafe-id.warn")"
  warn="$(cat "$OUT/unsafe-id.warn")"
  # 唯一一條規則的 id 不安全時整個區塊應該是空的，不是「有區塊但不含那條」。
  # 用 eq "" 直接講，比 lacks 精確：lacks 對空字串一定通過，那個綠燈的意思是
  # 「什麼都沒渲染」還是「渲染了但不含它」分不出來。
  eq "唯一一條規則的 id 不安全時，整個區塊是空的" "" "$block"
  has "印出 RULE_RENDER_SKIP_UNSAFE_ID" "$warn" "RULE_RENDER_SKIP_UNSAFE_ID"
}

test_invalid_budget_falls_back_to_default_with_warning() {
  local block warn
  block="$(rule_render_block "$FIX/rules" common abc 2>"$OUT/budget-invalid.warn")"
  warn="$(cat "$OUT/budget-invalid.warn")"
  has "非數字預算印出警告" "$warn" "RULE_BLOCK_BUDGET_INVALID"
  has "仍然照樣渲染（退回預設值）" "$block" "common-debug-artifact"
}

# ---------------------------------------------------------------------------
# rule_render_block：token 預算與排序（已裁決的限制：A、B 兩條路線在同一個
# 「取前 N 條」上限下注入量差了 2.9 倍，因為 A 路線規則數遠多於 B——改成
# token 預算逐條累加，依出處數由大到小、同分用 id 字典序，加上這條會超
# 預算就停，兩條路線才能公平比較）
# ---------------------------------------------------------------------------

test_render_block_takes_highest_ranked_rule_first() {
  local dir="$OUT/rank-basic"
  write_rank_rule "$dir" a-many nestjs 10
  write_rank_rule "$dir" b-many nestjs 10
  write_rank_rule "$dir" m-mid nestjs 5
  write_rank_rule "$dir" z-few nestjs 3
  # 預算剛好等於出處數最高那條規則自己的大小：逼所有排序都要對，任何
  # 第二名以後（不管是同分的 b-many 還是分數較低的 m-mid/z-few）都該被
  # 擋下來，因為累加上去一定超預算。
  local first_tokens
  first_tokens=$(( $(_rule_char_count "$(_rule_entry_text "$dir/a-many.md")") / 2 ))
  local block; block="$(rule_render_block "$dir" nestjs "$first_tokens")"
  has "出處數最高的 a-many 入選" "$block" "[a-many]"
  lacks "同分但排第二的 b-many 沒入選（加上去會超預算）" "$block" "[b-many]"
  lacks "出處數較低的 m-mid 沒入選" "$block" "[m-mid]"
  lacks "出處數最少的 z-few 沒入選" "$block" "[z-few]"
}

# 上一個測試如果只驗證「入選了 a-many」，排序退化成保留 for 迴圈展開
# *.md 的原始順序（沒有真的比較 id）也可能巧合通過（如果 fixture 檔名剛好
# 等於 id，字母序跟 glob 順序一致）。這裡故意讓檔名字母序跟 id 字典序相反：
# 如果實作真的依 id 字典序決定同分名次，「id 字典序較小」那個 id 該贏，
# 跟它的檔名或 glob 展開順序無關。
test_render_block_tie_break_is_by_id_not_glob_order() {
  local dir="$OUT/rank-tiebreak"
  write_rank_rule_named "$dir" aaa-glob-first zzz-id-last nestjs 10
  write_rank_rule_named "$dir" zzz-glob-last aaa-id-first nestjs 10
  local first_tokens
  first_tokens=$(( $(_rule_char_count "$(_rule_entry_text "$dir/zzz-glob-last.md")") / 2 ))
  local block; block="$(rule_render_block "$dir" nestjs "$first_tokens")"
  has "id 字典序較小的 aaa-id-first 入選（即使它的檔名／glob 順序在後）" \
    "$block" "[aaa-id-first]"
  lacks "id 字典序較大的 zzz-id-last 沒入選（即使它的檔名／glob 順序在前）" \
    "$block" "[zzz-id-last]"
}

# 預算剛好卡在兩條規則之間時，取第一條、不取第二條——同一組 fixture 再用
# 兩條合計的預算跑一次，證明「卡住」真的是跟預算大小有關，不是恆定的排除
# （否則第一個斷言可能只是巧合通過）。
test_budget_boundary_takes_first_rule_not_second() {
  local dir="$OUT/rank-boundary"
  write_rank_rule "$dir" boundary-first nestjs 10
  write_rank_rule "$dir" boundary-second nestjs 5
  local first_tokens second_tokens both_tokens
  first_tokens=$(( $(_rule_char_count "$(_rule_entry_text "$dir/boundary-first.md")") / 2 ))
  second_tokens=$(( $(_rule_char_count "$(_rule_entry_text "$dir/boundary-second.md")") / 2 ))
  both_tokens=$((first_tokens + second_tokens))

  local block; block="$(rule_render_block "$dir" nestjs "$first_tokens")"
  has "預算剛好卡在第一條大小時，第一條入選" "$block" "[boundary-first]"
  lacks "第二條沒入選（加上去會超預算）" "$block" "[boundary-second]"

  local block2; block2="$(rule_render_block "$dir" nestjs "$both_tokens")"
  has "預算夠大時，第一條仍然入選" "$block2" "[boundary-first]"
  has "預算夠大時，第二條也入選——證明前面卡住是預算大小造成的，不是恆定排除" \
    "$block2" "[boundary-second]"
}

# 至少收一條：即使第一條（唯一一條候選）自己就超過預算，也要收，不然
# 預算設太小時產出的是空區塊，跟「這層真的沒有規則」外觀上完全無法分辨。
test_first_rule_included_even_if_it_alone_exceeds_budget() {
  local dir="$OUT/rank-oversized"
  write_rank_rule "$dir" oversized-only nestjs 10
  local block; block="$(rule_render_block "$dir" nestjs 1)"  # 1 token，任何真實規則都裝不下
  has "預算小到連一條都裝不下時，仍然收下唯一一條" "$block" "[oversized-only]"
}

test_zero_or_negative_budget_warns_and_falls_back_to_default() {
  local block_zero warn_zero block_neg warn_neg
  block_zero="$(rule_render_block "$FIX/rules" common 0 2>"$OUT/budget-zero.warn")"
  warn_zero="$(cat "$OUT/budget-zero.warn")"
  has "預算 0 印出警告" "$warn_zero" "RULE_BLOCK_BUDGET_INVALID"
  has "退回預設值後仍然照樣渲染（不是靜默產出空區塊）" "$block_zero" "common-debug-artifact"

  block_neg="$(rule_render_block "$FIX/rules" common -5 2>"$OUT/budget-neg.warn")"
  warn_neg="$(cat "$OUT/budget-neg.warn")"
  has "負數預算印出警告" "$warn_neg" "RULE_BLOCK_BUDGET_INVALID"
  has "退回預設值後仍然照樣渲染（不是靜默產出空區塊）" "$block_neg" "common-debug-artifact"
}

test_render_block_is_deterministic() {
  local block1 block2
  block1="$(rule_render_block "$FIX/rules" nestjs 5000)"
  block2="$(rule_render_block "$FIX/rules" nestjs 5000)"
  eq "同樣輸入兩次產出完全一致（決定性）" "$block1" "$block2"
}

# 這是這次改動真正要解決的問題：改成 token 預算之前，A 路線（tfidf，
# common 層 81 條）在「取前 20 條」上限下永遠吃滿，B 路線（taxonomy，
# common 層只有 8 條）永遠吃不滿，注入量差了 2.9 倍——那是條數落差造成的
# prompt 長度落差，不是規則品質的差異，會污染兩條路線的回測比較。改成
# token 預算後，兩條路線在同一個預算下應該收斂到接近的注入量。
# 用自建 fixture，不讀 agents/review-rules/ 成品目錄：那個目錄是萃取階段的
# 產出，會被重新產生，也可能被清空。實測清空後兩條路線都是 1 char、差距 0%，
# 這支測試照樣綠 —— 它宣稱在驗的事情完全沒被驗到。
#
# fixture 反映真實的形狀：條數多的那邊每條短、條數少的那邊每條長，兩邊的
# 內容總量都遠超預算。實測回測時 taxonomy 的 8 條注入後是 20.5KB、tfidf 的
# 7 條是 18.3KB —— 條數少的那邊反而略大，因為它每條寫得比較長。
#
# 這個形狀才是 token 預算要處理的：兩邊都有足夠內容，差別只在怎麼切成條。
# 條數上限（取前 20 條）之下，40 條那邊拿 20 條、8 條那邊只有 8 條，注入量
# 由條數決定；token 預算之下兩邊都吃到預算上限，差距收斂。
#
# 第一版 fixture 用 40 條短的對 8 條短的，8 條那邊總量只有 935 chars、吃不滿
# 預算，差距 79%。那不是 token 預算的問題，是 fixture 沒有反映真實形狀。
_write_bulky_rule() {
  local dir="$1" id="$2" n_sources="$3" pad_lines="$4"
  local body="" i
  for ((i = 0; i < pad_lines; i++)); do
    body="${body}判準補充第 ${i} 行：這條規則的判準需要足夠的篇幅說明，才能反映"
    body="${body}真實規則檔的長度。實測 taxonomy 的規則平均比 tfidf 長。"$'\n'
  done
  local sources="" j
  for ((j = 0; j < n_sources; j++)); do
    sources="${sources}- https://github.com/o/r/pull/1#discussion_r${j}"$'\n'
  done
  cat > "$dir/$id.md" <<EOF
---
id: $id
layer: common
frameworks: ["*"]
severity_default: HIGH
---
## 觸發訊號
diff 中出現這個形狀。

## 判準
$body

## 嚴重度
HIGH：後果明確。

## 反例（不該報）
前提不成立時。

## 出處
$sources
EOF
}

test_two_routes_converge_in_block_size_under_same_budget() {
  local many few
  many="$TMP/route-many"; few="$TMP/route-few"
  mkdir -p "$many" "$few"
  local i
  # 40 條短的（每條約 2 行判準），總量遠超 5000 token
  for i in $(seq 1 40); do _write_bulky_rule "$many" "common-many-$i" 10 2; done
  # 8 條長的（每條約 12 行判準），總量同樣遠超 5000 token
  for i in $(seq 1 8);  do _write_bulky_rule "$few"  "common-few-$i"  10 12; done

  local many_block few_block many_chars few_chars
  many_block="$(rule_render_block "$many" nestjs 5000)"
  few_block="$(rule_render_block "$few" nestjs 5000)"
  many_chars="$(_rule_char_count "$many_block")"
  few_chars="$(_rule_char_count "$few_block")"

  # 兩邊都要真的渲染出規則。少了這道，空目錄會讓兩邊都只剩區塊標頭，差距
  # 計算得到一個小數字，看起來像「完美收斂」—— 原版就是這樣：讀成品目錄，
  # 目錄清空後兩邊都是 1 char、差距 0%、測試綠。
  #
  # 判準用「規則行的條數」不用字元數：空目錄時區塊標頭本身就有 500 字元以上，
  # 用字元數當門檻只是換一個猜出來的數字。
  local many_rules few_rules
  many_rules="$(printf '%s\n' "$many_block" | grep -c '^- \[' || true)"
  few_rules="$(printf '%s\n' "$few_block" | grep -c '^- \[' || true)"
  if [ "$many_rules" -lt 2 ] || [ "$few_rules" -lt 2 ]; then
    fail "區塊裡幾乎沒有規則，差距計算沒有意義：many=${many_rules} 條 few=${few_rules} 條"
    return
  fi

  local larger smaller diff pct
  if [ "$many_chars" -ge "$few_chars" ]; then
    larger="$many_chars"; smaller="$few_chars"
  else
    larger="$few_chars"; smaller="$many_chars"
  fi
  diff=$((larger - smaller))
  pct=$((diff * 100 / larger))
  # 兩邊的內容總量都遠超預算，所以在 token 預算下應該都吃到接近上限。
  # 條數上限（取前 20 條）之下，8 條那邊拿不滿，差距會拉開。
  [ "$pct" -le 30 ] \
    && ok "條數差 5 倍、每條長度也不同的兩個規則集，在同一個 5000 token 預算下區塊大小接近（差距 ${pct}%，40 條=${many_chars} chars 8 條=${few_chars} chars）" \
    || fail "差距 ${pct}% 太大，改回條數上限的問題可能還在：40 條=${many_chars} chars 8 條=${few_chars} chars"
}

# ---------------------------------------------------------------------------
# rule_inject_persona：注入位置與冪等性
# ---------------------------------------------------------------------------

test_inject_preserves_original_sections() {
  rule_inject_persona "$FIX/persona.md" "$(rule_render_block "$FIX/rules" nestjs)" "$OUT/p.md"
  local body; body="$(cat "$OUT/p.md")"
  has "ROLE 還在" "$body" "ROLE:"
  has "METHOD 還在" "$body" "METHOD:"
  has "OUTPUT FORMAT 還在" "$body" "OUTPUT FORMAT:"
}

test_inject_places_block_after_focus_and_before_scope_note() {
  rule_inject_persona "$FIX/persona.md" "$(rule_render_block "$FIX/rules" nestjs)" "$OUT/p-scope.md"
  local focus_line inject_line scope_line
  focus_line="$(grep -n '^FOCUS:' "$OUT/p-scope.md" | cut -d: -f1)"
  inject_line="$(grep -n 'BEGIN RULESET' "$OUT/p-scope.md" | head -1 | cut -d: -f1)"
  scope_line="$(grep -n '^SCOPE NOTE:' "$OUT/p-scope.md" | cut -d: -f1)"
  [ "$focus_line" -lt "$inject_line" ] && [ "$inject_line" -lt "$scope_line" ] \
    && ok "注入位置在 FOCUS 與 SCOPE NOTE 之間" \
    || fail "注入位置不對：focus=$focus_line inject=$inject_line scope=$scope_line"
}

# 這是回歸測試：brief 的參考實作硬找 `^SCOPE NOTE:` 當插入點，沒有這個區塊
# 的 persona（security-auditor.md、refactoring-sage.md、test-architect.md
# 三個都沒有）會落到 awk 的 END fallback，插到檔案最尾端——METHOD 和
# OUTPUT FORMAT 之後，而不是「FOCUS 之後」。改成找「FOCUS 結束後的下一個
# 頂層標題」才能不管有沒有 SCOPE NOTE 都插對位置。
test_inject_places_block_after_focus_when_no_scope_note() {
  rule_inject_persona "$FIX/persona-no-scope-note.md" \
    "$(rule_render_block "$FIX/rules" nestjs)" "$OUT/p-noscope.md"
  local focus_line inject_line method_line
  focus_line="$(grep -n '^FOCUS:' "$OUT/p-noscope.md" | cut -d: -f1)"
  inject_line="$(grep -n 'BEGIN RULESET' "$OUT/p-noscope.md" | head -1 | cut -d: -f1)"
  method_line="$(grep -n '^METHOD:' "$OUT/p-noscope.md" | cut -d: -f1)"
  [ "$focus_line" -lt "$inject_line" ] && [ "$inject_line" -lt "$method_line" ] \
    && ok "沒有 SCOPE NOTE 時注入位置在 FOCUS 之後、METHOD 之前（不是檔尾）" \
    || fail "注入位置不對：focus=$focus_line inject=$inject_line method=$method_line"
}

test_persona_without_focus_fails_loudly() {
  local out rc
  out="$(rule_inject_persona "$FIX/persona-no-focus.md" "some block" "$OUT/nf.md" 2>&1)"
  rc=$?
  [ "$rc" -ne 0 ] && ok "沒有 FOCUS 退出碼非 0" || fail "應退出非 0"
  has "印出 PERSONA_NO_FOCUS" "$out" "PERSONA_NO_FOCUS"
  [ ! -e "$OUT/nf.md" ] && ok "沒有寫出輸出檔" || fail "不該寫出輸出檔"
}

test_persona_missing_file_fails_loudly() {
  local out rc
  out="$(rule_inject_persona "$OUT/does-not-exist-persona.md" "block" "$OUT/pm.md" 2>&1)"
  rc=$?
  [ "$rc" -ne 0 ] && ok "persona 不存在時退出碼非 0" || fail "應退出非 0"
  has "印出 PERSONA_MISSING" "$out" "PERSONA_MISSING"
}

test_inject_is_idempotent() {
  local block; block="$(rule_render_block "$FIX/rules" nestjs)"
  rule_inject_persona "$FIX/persona.md" "$block" "$OUT/once.md"
  rule_inject_persona "$OUT/once.md" "$block" "$OUT/twice.md"
  eq "RULESET 標記只出現一次" "1" "$(grep -c 'BEGIN RULESET' "$OUT/twice.md")"
  has "規則內容還在" "$(cat "$OUT/twice.md")" "nestjs-injectable-scope"
}

# 冪等性不能只看「BEGIN 標記只出現一次」——插入邏輯在 END 標記後面多印一行
# 空白當跟下一個頂層標題的間距，但那行空白不在 BEGIN/END 界線之內，單純
# 剝除 BEGIN..END 不會連它一起拿掉。如果剝除邏輯沒有對稱地也吞掉這行，
# 「BEGIN 只出現一次」這個訊號完全看不出來，因為它每輪都真的只出現一次，
# 但空白行會一輪一輪地堆積。這裡連續注入三輪，直接比較第一輪跟第三輪的
# 完整內容是否逐位元組相同，才驗得出這個問題。
test_inject_is_idempotent_across_multiple_rounds() {
  local block; block="$(rule_render_block "$FIX/rules" nestjs)"
  rule_inject_persona "$FIX/persona.md" "$block" "$OUT/round1.md"
  rule_inject_persona "$OUT/round1.md" "$block" "$OUT/round2.md"
  rule_inject_persona "$OUT/round2.md" "$block" "$OUT/round3.md"
  if diff -q "$OUT/round1.md" "$OUT/round3.md" >/dev/null; then
    ok "連續注入三輪後，第一輪與第三輪內容逐位元組相同（沒有空白行堆積）"
  else
    fail "第一輪與第三輪內容不同——重複注入之間有東西在堆積：$(diff "$OUT/round1.md" "$OUT/round3.md")"
  fi
}

test_reinject_with_empty_block_removes_old_block() {
  local block; block="$(rule_render_block "$FIX/rules" nestjs)"
  rule_inject_persona "$FIX/persona.md" "$block" "$OUT/withblock.md"
  rule_inject_persona "$OUT/withblock.md" "" "$OUT/cleaned.md"
  eq "清空後不再有 RULESET 標記" "0" "$(grep -c 'BEGIN RULESET' "$OUT/cleaned.md")"
  has "原本的 ROLE 還在" "$(cat "$OUT/cleaned.md")" "ROLE:"
}

# 使用者手寫、剛好長得像我們自動產生標記的一行，但沒有對應的 END——上一輪
# 注入被中斷也會留下一樣的形狀。兩種成因都該被同一個防線擋下：拒絕注入，
# 不要把 BEGIN 之後的內容（這裡刻意放一行看得出來的內容 + METHOD）靜默吃掉。
test_existing_unterminated_begin_marker_is_rejected() {
  {
    printf 'ROLE: X\n'
    printf 'FOCUS:\n- a\n\n'
    printf '%s\n' "$RULE_BLOCK_BEGIN"
    printf 'hand-written content with no END marker\n'
    printf 'METHOD:\n1. y\n'
  } > "$OUT/broken.md"
  local out rc
  out="$(rule_inject_persona "$OUT/broken.md" "" "$OUT/broken-out.md" 2>&1)"
  rc=$?
  [ "$rc" -ne 0 ] && ok "未閉合的 BEGIN 標記讓注入拒絕執行" || fail "應該拒絕，避免截斷內容"
  has "印出 RULESET_STRIP_UNTERMINATED" "$out" "RULESET_STRIP_UNTERMINATED"
  [ ! -e "$OUT/broken-out.md" ] && ok "沒有寫出半殘的輸出檔" || fail "不該寫出輸出檔"
}

# ---------------------------------------------------------------------------
# rule_inject_all
# ---------------------------------------------------------------------------

# 直接對真實的 agents/personas/ 跑（不覆蓋第四個參數），驗證：
#   1. 不依賴外部 MRA_DIR（brief 參考實作用了 ${MRA_DIR} 卻沒有定義它）——
#      這裡先 unset，函式自己用 BASH_SOURCE 算出 repo 根目錄。
#   2. 每個內建 persona 都被處理到（含完全沒有 FOCUS 的 test-architect.md）。
test_inject_all_default_persona_dir_resolves_without_external_mra_dir() {
  unset MRA_DIR
  local n
  n="$(rule_inject_all "$FIX/rules" nestjs "$OUT/default-personas-out" 2>"$OUT/default.warn")"
  # PERSONA_TOTAL 在檔頭就算好了，不受這個函式的 unset MRA_DIR 影響。
  eq "處理了 agents/personas 底下每個 persona（不含 README）" "$PERSONA_TOTAL" "$n"
  [ -f "$OUT/default-personas-out/security-auditor.md" ] \
    && ok "security-auditor.md 產出了" || fail "security-auditor.md 沒產出"
  [ -f "$OUT/default-personas-out/test-architect.md" ] \
    && ok "test-architect.md 也產出了（即使它沒有 FOCUS）" || fail "test-architect.md 沒產出"
  has "test-architect.md 沒有 FOCUS，印出略過警告" \
    "$(cat "$OUT/default.warn")" "RULE_INJECT_SKIPPED"
  MRA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
}

# 這是對「brief 已知問題」清單裡第二個真的重現得出來的洞的回歸測試：
# rule_inject_all 原本一個 persona 失敗就整批 return 1，遇到
# test-architect.md（沒有 FOCUS）會在處理到一半中止，前面已經注入的
# persona 副本留在輸出目錄裡、函式卻回報失敗——輸出目錄看起來像成功產出
# 但其實不完整。改成遇到「沒有 FOCUS」原樣複製、繼續處理下一個。
test_inject_all_skips_no_focus_persona_without_aborting_batch() {
  mkdir -p "$OUT/mixed-personas"
  cp "$FIX/persona.md" "$OUT/mixed-personas/has-focus.md"
  cp "$FIX/persona-no-focus.md" "$OUT/mixed-personas/no-focus.md"
  local n
  n="$(rule_inject_all "$FIX/rules" nestjs "$OUT/mixed-out" "$OUT/mixed-personas" 2>"$OUT/mixed.warn")"
  eq "兩個 persona 都被處理（一個注入、一個原樣複製）" "2" "$n"
  has "has-focus.md 有注入 RULESET" "$(cat "$OUT/mixed-out/has-focus.md")" "BEGIN RULESET"
  lacks "no-focus.md 沒有 RULESET（原樣複製）" "$(cat "$OUT/mixed-out/no-focus.md")" "BEGIN RULESET"
  has "no-focus.md 原本內容還在" "$(cat "$OUT/mixed-out/no-focus.md")" "KENT BECK 11 PRINCIPLES"
  has "印出略過警告" "$(cat "$OUT/mixed.warn")" "RULE_INJECT_SKIPPED"
}

test_inject_all_fails_loudly_when_persona_src_missing() {
  local out rc
  out="$(rule_inject_all "$FIX/rules" nestjs "$OUT/no-src-out" "$OUT/does-not-exist-personas" 2>&1)"
  rc=$?
  [ "$rc" -ne 0 ] && ok "persona 來源目錄不存在時退出碼非 0" || fail "應該退出非 0"
  has "印出 RULE_INJECT_PERSONA_SRC_MISSING" "$out" "RULE_INJECT_PERSONA_SRC_MISSING"
}

# 第五個參數（token_budget）是 Task 8 補上的：run-rule-backtest.sh 要能覆寫
# token 預算並讓它真的傳到 rule_render_block，這裡直接驗證轉傳確實發生（用
# 一個小到只能收下出處數最高那條規則的預算，觀察注入結果只含那一條）。
test_inject_all_forwards_explicit_token_budget_to_render_block() {
  local dir="$OUT/budget-forward-rules"
  write_rank_rule "$dir" budget-fwd-many nestjs 10
  write_rank_rule "$dir" budget-fwd-few nestjs 3
  local tiny_budget
  tiny_budget=$(( $(_rule_char_count "$(_rule_entry_text "$dir/budget-fwd-many.md")") / 2 ))
  mkdir -p "$OUT/budget-fwd-personas"
  cp "$FIX/persona.md" "$OUT/budget-fwd-personas/has-focus.md"
  rule_inject_all "$dir" nestjs "$OUT/budget-fwd-out" "$OUT/budget-fwd-personas" \
    "$tiny_budget" >/dev/null 2>"$OUT/budget-fwd.warn"
  local body; body="$(cat "$OUT/budget-fwd-out/has-focus.md")"
  has "出處數最高的規則入選（預算轉傳生效）" "$body" "[budget-fwd-many]"
  lacks "出處數較低的規則沒入選（加上去會超過轉傳的小預算）" "$body" "[budget-fwd-few]"
}

# 省略第五個參數要完全不改變既有行為：不能連呼叫 rule_render_block 時都多帶
# 一個空字串當預算——那樣會被判定成畸形輸入，印出 RULE_BLOCK_BUDGET_INVALID
# 這種對「呼叫端根本沒打算覆寫」的正常呼叫而言是誤報的警告。
test_inject_all_omitted_budget_does_not_warn() {
  mkdir -p "$OUT/budget-omit-personas"
  cp "$FIX/persona.md" "$OUT/budget-omit-personas/has-focus.md"
  rule_inject_all "$FIX/rules" nestjs "$OUT/budget-omit-out" \
    "$OUT/budget-omit-personas" >/dev/null 2>"$OUT/budget-omit.warn"
  # 省略預算參數是完全正常的呼叫，stderr 應該一個字都沒有，不只是「沒有那個
  # 特定的 token」。用 eq "" 比 lacks 強：多印了任何別的警告也會被抓到。
  eq "省略預算參數時 stderr 完全沒有輸出" "" "$(cat "$OUT/budget-omit.warn")"
}

# =============================================================================
# 預算配額：層規則保底半數，兩邊用不完的額度互相退還
#
# 這組測試針對分層注入真正的失敗形狀。把層規則與 common 規則混在一起照出處
# 數排的話，common 規則的出處數普遍較高（它們在多個 repo 都被講過），層規則
# 會被整批擠掉——實測 tfidf 路線的 react／vue／nestjs 三層在 5000 預算下層
# 規則 0 條進得去。那時「分層注入」是個假動作：layer 參數換成 rails 了，
# prompt 裡卻還是只有 common，而且外觀上完全看不出來。
# =============================================================================

test_layer_rules_survive_even_when_common_ranks_higher() {
  local dir="$OUT/quota"
  write_rank_rule "$dir" common-top-1 common 50
  write_rank_rule "$dir" common-top-2 common 40
  write_rank_rule "$dir" nestjs-low nestjs 1
  # 預算只夠兩條。混排的話出處數 50 與 40 的兩條 common 會把出處數 1 的層
  # 規則擠掉；有保底配額時層規則一定拿得到位置。
  local one two
  one=$(( $(_rule_char_count "$(_rule_entry_text "$dir/common-top-1.md")") / 2 ))
  two=$((one * 2))
  local block; block="$(rule_render_block "$dir" nestjs "$two")"
  has "出處數最低的層規則仍然入選（層規則保底半數預算）" "$block" "[nestjs-low]"
  has "common 拿走剩下的額度" "$block" "[common-top-1]"
  lacks "第二條 common 被擋在預算外（總量沒有因為配額而膨脹）" "$block" "[common-top-2]"
}

test_unused_layer_quota_goes_back_to_common() {
  local dir="$OUT/quota-refund-common"
  write_rank_rule "$dir" common-a common 50
  write_rank_rule "$dir" common-b common 40
  write_rank_rule "$dir" common-c common 30
  # 這一層沒有自己的規則：整個預算都該給 common，不是只給一半。少了這道，
  # 一個只有 common 規則的規則集會平白損失一半預算。
  local one; one=$(( $(_rule_char_count "$(_rule_entry_text "$dir/common-a.md")") / 2 ))
  local block; block="$(rule_render_block "$dir" nestjs $((one * 3)))"
  has "第三條 common 也入選（層規則沒用到的額度退還）" "$block" "[common-c]"
}

test_unused_common_quota_goes_back_to_layer_rules() {
  local dir="$OUT/quota-refund-layer"
  write_rank_rule "$dir" nestjs-a nestjs 50
  write_rank_rule "$dir" nestjs-b nestjs 40
  write_rank_rule "$dir" nestjs-c nestjs 30
  # 沒有 common 規則：三條層規則該全部進得去。只做「層規則拿一半」而沒有
  # 第三輪補收的話，這裡只會進得去一條。
  local one; one=$(( $(_rule_char_count "$(_rule_entry_text "$dir/nestjs-a.md")") / 2 ))
  local block; block="$(rule_render_block "$dir" nestjs $((one * 3)))"
  has "第二條層規則入選" "$block" "[nestjs-b]"
  has "第三條層規則也入選（common 沒用到的額度退還）" "$block" "[nestjs-c]"
}

# layer 傳 common 時沒有「層規則」這個分組（common 規則歸在 common 那一份，
# 不會同時算成層規則），整段要退化成「用全部預算收 common」——階段二的基準線
# 就是這樣跑出來的，行為變了就不能拿來比。
test_common_layer_still_gets_the_whole_budget() {
  local dir="$OUT/quota-common-layer"
  write_rank_rule "$dir" common-x common 50
  write_rank_rule "$dir" common-y common 40
  write_rank_rule "$dir" common-z common 30
  local one; one=$(( $(_rule_char_count "$(_rule_entry_text "$dir/common-x.md")") / 2 ))
  local block; block="$(rule_render_block "$dir" common $((one * 3)))"
  has "第三條也入選（layer=common 時預算沒有被對半切）" "$block" "[common-z]"
}

# =============================================================================
# rule_inject_layers：每層各一份 persona 副本
# =============================================================================

test_inject_layers_creates_one_dir_per_layer() {
  local out="$OUT/layers-out" report
  report="$(rule_inject_layers "$FIX/rules" "$out" "nestjs react vue" "" "" \
    2>"$OUT/layers.warn")"
  eq "每層各一行報告" "3" "$(printf '%s\n' "$report" | grep -c . || true)"
  if [ -f "$out/nestjs/security-auditor.md" ] && [ -f "$out/react/security-auditor.md" ] \
     && [ -f "$out/vue/security-auditor.md" ]; then
    ok "三層各有一份完整的 persona 副本"
  else
    fail "缺少某一層的 persona 副本：$out"
  fi
  local nest; nest="$(cat "$out/nestjs/security-auditor.md")"
  has "nestjs 層含 nestjs 規則" "$nest" "nestjs-injectable-scope"
  lacks "nestjs 層不含 react 規則" "$nest" "react-effect-cleanup"
  has "nestjs 層仍含 common 規則" "$nest" "common-debug-artifact"
}

test_inject_layers_report_has_four_columns() {
  local out="$OUT/layers-cols" report
  report="$(rule_inject_layers "$FIX/rules" "$out" "vue" "" "" 2>"$OUT/layers-cols.warn")"
  eq "第一欄是層名" "vue" "$(printf '%s' "$report" | cut -f1)"
  eq "第二欄是 persona 總數" "$PERSONA_TOTAL" "$(printf '%s' "$report" | cut -f2)"
  eq "第三欄是沒有 FOCUS 而跳過的數量" "1" "$(printf '%s' "$report" | cut -f3)"
  # 這份 fixture 只有 common、nestjs、react 各一條，vue 層看得到的只有
  # common 那一條。這一欄要回答的正是「這一層實際有幾條規則進了 prompt」，
  # 規則檔總數回答不了。
  eq "第四欄是實際注入的規則條數" "1" "$(printf '%s' "$report" | cut -f4)"
}

# 層名會直接組成輸出路徑。清單來源是 corpus_layers()、不是模型輸出，但一個
# 帶 ../ 的層名會讓注入結果寫到 out_root 之外，而外觀上跟正常執行沒有差別。
test_inject_layers_rejects_unsafe_layer_name() {
  local rc
  rule_inject_layers "$FIX/rules" "$OUT/layers-unsafe" "../escape" "" "" \
    2>"$OUT/layers-unsafe.warn"
  rc=$?
  if [ "$rc" -ne 0 ]; then ok "不安全的層名讓注入失敗"; else fail "不安全的層名必須擋下來"; fi
  has "印出 RULE_INJECT_LAYER_UNSAFE" "$(cat "$OUT/layers-unsafe.warn")" \
    "RULE_INJECT_LAYER_UNSAFE"
}

# 空的層清單多半是呼叫端把 corpus_layers() 的輸出接壞了。悄悄回傳 0 的話，
# 呼叫端會拿到一個空的注入根目錄，而每個 PR 都會落回沒有規則的 persona。
test_inject_layers_rejects_empty_layer_list() {
  local rc
  rule_inject_layers "$FIX/rules" "$OUT/layers-empty" "" "" "" \
    2>"$OUT/layers-empty.warn"
  rc=$?
  if [ "$rc" -ne 0 ]; then ok "空的層清單讓注入失敗"; else fail "空的層清單必須擋下來"; fi
  has "印出 RULE_INJECT_NO_LAYERS" "$(cat "$OUT/layers-empty.warn")" "RULE_INJECT_NO_LAYERS"
}

test_inject_layers_forwards_token_budget() {
  local dir="$OUT/layers-budget" out="$OUT/layers-budget-out"
  write_rank_rule "$dir" budget-many nestjs 10
  write_rank_rule "$dir" budget-few nestjs 3
  local one; one=$(( $(_rule_char_count "$(_rule_entry_text "$dir/budget-many.md")") / 2 ))
  rule_inject_layers "$dir" "$out" "nestjs" "" "$one" 2>"$OUT/layers-budget.warn"
  local body; body="$(cat "$out/nestjs/security-auditor.md")"
  has "出處數最高的規則入選（預算有轉傳到 rule_render_block）" "$body" "[budget-many]"
  lacks "出處數較低的規則被排除" "$body" "[budget-few]"
}

# =============================================================================
# 靜態檢查：這個專案已經為「2>/dev/null 吞掉診斷」付過四次代價，鎖住
# lib/rule-inject.sh 裡不會出現這個模式。
# =============================================================================
test_lib_never_discards_stderr_with_dev_null() {
  lacks "lib/rule-inject.sh 沒有 2>/dev/null" \
    "$(cat "$MRA_DIR/lib/rule-inject.sh")" "2>/dev/null"
}

test_block_contains_trigger_and_criteria
test_block_excludes_other_layers
test_block_includes_common_layer_for_any_layer
test_block_omits_sources
test_empty_ruleset_produces_no_block
test_missing_rules_dir_warns_and_returns_empty
test_unsafe_id_is_skipped_with_warning
test_invalid_budget_falls_back_to_default_with_warning
test_render_block_takes_highest_ranked_rule_first
test_render_block_tie_break_is_by_id_not_glob_order
test_budget_boundary_takes_first_rule_not_second
test_first_rule_included_even_if_it_alone_exceeds_budget
test_zero_or_negative_budget_warns_and_falls_back_to_default
test_render_block_is_deterministic
test_two_routes_converge_in_block_size_under_same_budget
test_inject_preserves_original_sections
test_inject_places_block_after_focus_and_before_scope_note
test_inject_places_block_after_focus_when_no_scope_note
test_persona_without_focus_fails_loudly
test_persona_missing_file_fails_loudly
test_inject_is_idempotent
test_inject_is_idempotent_across_multiple_rounds
test_reinject_with_empty_block_removes_old_block
test_existing_unterminated_begin_marker_is_rejected
test_inject_all_default_persona_dir_resolves_without_external_mra_dir
test_inject_all_skips_no_focus_persona_without_aborting_batch
test_inject_all_fails_loudly_when_persona_src_missing
test_inject_all_forwards_explicit_token_budget_to_render_block
test_inject_all_omitted_budget_does_not_warn
test_layer_rules_survive_even_when_common_ranks_higher
test_unused_layer_quota_goes_back_to_common
test_unused_common_quota_goes_back_to_layer_rules
test_common_layer_still_gets_the_whole_budget
test_inject_layers_creates_one_dir_per_layer
test_inject_layers_report_has_four_columns
test_inject_layers_rejects_unsafe_layer_name
test_inject_layers_rejects_empty_layer_list
test_inject_layers_forwards_token_budget
test_lib_never_discards_stderr_with_dev_null

echo "---"; echo "Passed: $pass"; echo "Failed: $errors"
exit $((errors > 0 ? 1 : 0))
