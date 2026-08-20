#!/usr/bin/env bash
# 規則注入 persona 的 FOCUS 區塊 (lib/rule-inject.sh)。
#
# 這支測試除了驗基本渲染／注入之外，特別針對 task-6-brief.md 參考實作裡
# 已知會踩到的三個地方各補一組測試：
#   1. rule_render_block 的上限（common 層規則太多，注入區塊會炸到 80 KB／
#      4 萬 token）——上限、排序（出處數大到小、同分用 id 字典序）、
#      非數字上限的容錯都要測。
#   2. rule_inject_persona 的注入錨點不能寫死找 `^SCOPE NOTE:`——
#      agents/personas/ 裡五個 persona 只有兩個真的有 SCOPE NOTE
#      （performance-hawk.md、api-contract-guardian.md），其餘三個
#      （security-auditor.md、refactoring-sage.md、test-architect.md）
#      沒有，若硬找 SCOPE NOTE 會讓沒有它的 persona 注入位置掉到檔尾、
#      METHOD 和 OUTPUT FORMAT 之後。
#   3. rule_inject_all 對 agents/personas/test-architect.md 這種完全沒有
#      FOCUS 區塊（用「KENT BECK 11 PRINCIPLES:」取代）的 persona 不能中止
#      整批，也不能吞掉不處理，要原樣複製並印警告，讓 review 流程仍然讀
#      得到它。
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
lacks(){ case "$2" in *"$3"*) fail "$1 — 不該看到「$3」：$2" ;; *) ok "$1" ;; esac; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/rule-inject-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

FIX="$MRA_DIR/tests/fixtures/rule-inject"
OUT="$TMP/out"
mkdir -p "$OUT"

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
  lacks "不安全的 id 沒有被渲染進區塊（樣板本身雖然有前後綴保護，仍不放行）" \
    "$block" "$RULE_BLOCK_END"
  has "印出 RULE_RENDER_SKIP_UNSAFE_ID" "$warn" "RULE_RENDER_SKIP_UNSAFE_ID"
}

test_invalid_limit_falls_back_to_default_with_warning() {
  local block warn
  block="$(rule_render_block "$FIX/rules" common abc 2>"$OUT/limit-invalid.warn")"
  warn="$(cat "$OUT/limit-invalid.warn")"
  has "非數字上限印出警告" "$warn" "RULE_BLOCK_LIMIT_INVALID"
  has "仍然照樣渲染（退回預設值）" "$block" "common-debug-artifact"
}

# ---------------------------------------------------------------------------
# rule_render_block：上限與排序（已裁決的限制：common 層只取前 N 條，
# 出處數由大到小，同分用 id 字典序）
# ---------------------------------------------------------------------------

test_limit_takes_top_n_by_source_count_desc() {
  local dir="$OUT/rank-basic"
  write_rank_rule "$dir" a-many nestjs 10
  write_rank_rule "$dir" b-many nestjs 10
  write_rank_rule "$dir" m-mid nestjs 5
  write_rank_rule "$dir" z-few nestjs 3
  local block; block="$(rule_render_block "$dir" nestjs 2)"
  has "含出處數最高的 a-many" "$block" "[a-many]"
  has "含出處數並列最高的 b-many" "$block" "[b-many]"
  lacks "不含排第三的 m-mid" "$block" "[m-mid]"
  lacks "不含出處數最少的 z-few" "$block" "[z-few]"
}

test_limit_tie_break_by_id_ascending() {
  local dir="$OUT/rank-basic"  # 沿用上一個測試建立的 fixture
  local block; block="$(rule_render_block "$dir" nestjs 1)"
  has "同分時 id 字典序較小的 a-many 入選" "$block" "[a-many]"
  lacks "同分但字典序較大的 b-many 沒入選" "$block" "[b-many]"
}

# 上一個測試用的 fixture 檔名剛好等於 id，字母序跟 glob 展開順序一致，
# 就算排序退化成「沒有真的比較 id、只是保留 for 迴圈展開 *.md 的原始順
# 序」也會巧合地通過。這裡故意讓檔名字母序跟 id 字典序相反：如果實作真的
# 依 id 字典序決定同分名次，「id 字典序較小」那個 id 該贏，跟它的檔名或
# glob 展開順序無關。
test_limit_tie_break_is_by_id_not_glob_order() {
  local dir="$OUT/rank-tiebreak"
  write_rank_rule_named "$dir" aaa-glob-first zzz-id-last nestjs 10
  write_rank_rule_named "$dir" zzz-glob-last aaa-id-first nestjs 10
  local block; block="$(rule_render_block "$dir" nestjs 1)"
  has "id 字典序較小的 aaa-id-first 入選（即使它的檔名／glob 順序在後）" \
    "$block" "[aaa-id-first]"
  lacks "id 字典序較大的 zzz-id-last 沒入選（即使它的檔名／glob 順序在前）" \
    "$block" "[zzz-id-last]"
}

test_default_limit_is_20() {
  local dir="$OUT/rank-default" i
  for ((i = 1; i <= 21; i++)); do
    write_rank_rule "$dir" "$(printf 'r%02d' "$i")" nestjs "$((30 - i))"
  done
  local block; block="$(rule_render_block "$dir" nestjs)"  # 不傳第三個參數
  has "第 1 名（出處數最高）入選" "$block" "[r01]"
  has "第 20 名剛好卡在上限內" "$block" "[r20]"
  lacks "第 21 名（出處數最低）被上限排除" "$block" "[r21]"
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
#   2. 五個 persona 都被處理到（含完全沒有 FOCUS 的 test-architect.md）。
test_inject_all_default_persona_dir_resolves_without_external_mra_dir() {
  unset MRA_DIR
  local n
  n="$(rule_inject_all "$FIX/rules" nestjs "$OUT/default-personas-out" 2>"$OUT/default.warn")"
  eq "處理了 agents/personas 底下 5 個 persona（不含 README）" "5" "$n"
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
test_invalid_limit_falls_back_to_default_with_warning
test_limit_takes_top_n_by_source_count_desc
test_limit_tie_break_by_id_ascending
test_limit_tie_break_is_by_id_not_glob_order
test_default_limit_is_20
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
test_lib_never_discards_stderr_with_dev_null

echo "---"; echo "Passed: $pass"; echo "Failed: $errors"
exit $((errors > 0 ? 1 : 0))
