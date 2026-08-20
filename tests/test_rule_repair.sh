#!/usr/bin/env bash
# 規則檔格式修復 pass (scripts/rule-repair.sh)。
#
# 修復的唯一動作是在 frontmatter 收尾插入一行 ---。這個動作看起來無害，但它
# 是「把不合格改成合格」的操作，做錯的話會讓壞檔案變成看起來合格的、而且
# 沒有任何錯誤訊號——task-4b-brief.md 因此把七個邊界列成這個任務的重點，
# 每一個都要有測試，不能只測「正常情況能修好」。
set -uo pipefail
MRA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$MRA_DIR/lib/corpus-targets.sh"
source "$MRA_DIR/lib/rule-schema.sh"

errors=0; pass=0
ok()   { echo "PASS: $1"; pass=$((pass+1)); }
fail() { echo "FAIL: $1"; errors=$((errors+1)); }
eq()   { if [[ "$2" == "$3" ]]; then ok "$1"; else fail "$1 — expected [$2] got [$3]"; fi; }
has()  { case "$2" in *"$3"*) ok "$1" ;; *) fail "$1 — 沒看到「$3」：$2" ;; esac; }
lacks(){ case "$2" in *"$3"*) fail "$1 — 不該看到「$3」：$2" ;; *) ok "$1" ;; esac; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/rule-repair-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

run_repair() {
  # $1=rejected 目錄 $2=out 目錄
  bash "$MRA_DIR/scripts/rule-repair.sh" --rejected "$1" --out "$2"
}

count_md() {
  ls "$1"/*.md 2>/dev/null | wc -l | tr -d ' '
}

# 標準的六個必要章節、三則出處——附加在 frontmatter 之後，讓每個 fixture
# 除了「要測的那個邊界」以外，其餘部分都合格，這樣測試斷言才乾淨（不會被
# 別的、不相干的驗證失敗污染判讀）。
write_valid_body() {
  cat <<'EOF'
## 觸發訊號
diff 裡出現這個模式。

## 判準
這是判準內容，說明為什麼這個模式有問題。

## 嚴重度
CRITICAL：最嚴重的情況
HIGH：次嚴重的情況
MEDIUM：影響較小的情況

## 反例（不該報）
這種情況不該報。

## 出處
- https://github.com/example/repo/pull/1#discussion_r1
- https://github.com/example/repo/pull/2#discussion_r2
- https://github.com/example/repo/pull/3#discussion_r3
EOF
}

# =============================================================================
# 基本情況：缺收尾 --- 的正常案例（44 個真實 _rejected 檔案裡 34 個的形狀）。
# 檔名故意用 cluster tag（跟 id 不一樣），同時涵蓋邊界 6。
# =============================================================================
test_basic_missing_closer_gets_rescued() {
  local rejected="$TMP/basic-in" out="$TMP/basic-out"
  mkdir -p "$rejected" "$out"
  {
    printf '%s\n' '---' 'id: common-basic-missing-closer' 'layer: common' \
      'frameworks: ["*"]' 'severity_default: HIGH' ''
    write_valid_body
  } > "$rejected/common-clusters-99.md"

  local out_msg; out_msg="$(run_repair "$rejected" "$out" 2>"$TMP/basic.err")"
  local rc=$?
  eq "退出碼是 0（沒有撞名衝突）" "0" "$rc"
  has "印出救回 1" "$out_msg" "救回 1"
  has "印出仍不通過 0" "$out_msg" "仍不通過 0"
  eq "以 id 命名，不是沿用原檔名（邊界 6）" "1" \
    "$([ -f "$out/common-basic-missing-closer.md" ] && echo 1 || echo 0)"
  eq "原檔名沒有出現在 out 目錄" "0" \
    "$([ -f "$out/common-clusters-99.md" ] && echo 1 || echo 0)"
  eq "原始檔案已從 _rejected 移除（搬過去，不是複製）" "0" \
    "$([ -f "$rejected/common-clusters-99.md" ] && echo 1 || echo 0)"
  rule_validate "$out/common-basic-missing-closer.md" 2>"$TMP/basic-validate.err" \
    && ok "搬過去的檔案通過 rule_validate" \
    || fail "搬過去的檔案應該通過驗證：$(cat "$TMP/basic-validate.err")"
}

# =============================================================================
# 邊界 1：frontmatter 已經有成對的 ---，且因為別的原因（出處不足）仍不通過。
# 修復不能把它弄壞——不該多插入第二個 ---，也不該動任何內容。
# =============================================================================
test_boundary1_already_closed_stays_untouched_when_still_invalid() {
  local rejected="$TMP/b1-in" out="$TMP/b1-out"
  mkdir -p "$rejected" "$out"
  cat > "$rejected/nestjs-clusters-3.md" <<'EOF'
---
id: nestjs-already-closed-few-sources
layer: nestjs
frameworks: ["@nestjs/core@>=9"]
severity_default: HIGH
---
## 觸發訊號
diff 裡出現這個模式。

## 判準
這是判準內容。

## 嚴重度
CRITICAL：最嚴重
HIGH：次嚴重
MEDIUM：較輕

## 反例（不該報）
這種情況不該報。

## 出處
- https://github.com/example/repo/pull/1#discussion_r1
- https://github.com/example/repo/pull/2#discussion_r2
EOF
  local before; before="$(cat "$rejected/nestjs-clusters-3.md")"

  local out_msg; out_msg="$(run_repair "$rejected" "$out" 2>"$TMP/b1.err")"
  has "印出仍不通過 1" "$out_msg" "仍不通過 1"
  has "印出救回 0" "$out_msg" "救回 0"
  eq "沒有搬到 out" "0" "$(count_md "$out")"

  local after; after="$([ -f "$rejected/nestjs-clusters-3.md" ] && cat "$rejected/nestjs-clusters-3.md" || echo MISSING)"
  eq "原始檔案內容一個位元組都沒被改動" "$before" "$after"

  local dash_count; dash_count="$(grep -cx -- '---' "$rejected/nestjs-clusters-3.md")"
  eq "沒有被插入第二個 ---（仍然只有一對）" "2" "$dash_count"
  has "訊息說明是驗證仍未通過（不是插入失敗）" "$(cat "$TMP/b1.err")" "RULE_REPAIR_STILL_INVALID"
}

# 邊界 1 的另一面：已經封好 --- 的檔案如果其實已經合格（只是不知何故落在
# _rejected），修復不能因為「已經封好就不處理」而放棄搶救——應該原封不動地
# 送去驗證、通過就搬走，且內容要跟原檔案逐位元組一致（因為沒有插入任何東西）。
test_boundary1_already_closed_and_actually_valid_is_rescued_unmodified() {
  local rejected="$TMP/b1v-in" out="$TMP/b1v-out"
  mkdir -p "$rejected" "$out"
  {
    printf '%s\n' '---' 'id: vue-already-closed-valid' 'layer: vue' \
      'frameworks: ["vue@>=3"]' 'severity_default: MEDIUM' '---'
    write_valid_body
  } > "$rejected/vue-clusters-1.md"
  local before; before="$(cat "$rejected/vue-clusters-1.md")"

  local out_msg; out_msg="$(run_repair "$rejected" "$out" 2>"$TMP/b1v.err")"
  has "印出救回 1" "$out_msg" "救回 1"
  eq "以 id 命名搬到 out" "1" \
    "$([ -f "$out/vue-already-closed-valid.md" ] && echo 1 || echo 0)"
  local after; after="$(cat "$out/vue-already-closed-valid.md")"
  eq "內容逐位元組不變（沒有多插入 ---）" "$before" "$after"
}

# =============================================================================
# 邊界 2：第一個 ## 出現在（NR>1 的）任何候選收尾 --- 之前——也就是唯一一個
# 候選收尾 --- 出現在 heading 之後（本例是內文裡的分隔線），不是真正在收尾
# frontmatter。這不是缺收尾，是格式整個壞掉，不該插入。
#
# 這個 fixture 除了「該檢查」以外，其餘全部合格（六個必要章節、三則出處）——
# 刻意讓它變成「如果插入了會怎樣」有辨別力的案例：如果拿掉這道檢查、放行
# INSERT，插入點剛好會落在第一個 ## 之前，產生一份逐節看起來完全合格、會
# 被 rule_validate 放行、進而被靜默搬進 <out> 的規則檔——而它的 frontmatter
# 其實從來沒有真正收尾過。只測「不可修復」這個結論還不夠，這個 fixture 要
# 能證明「如果做錯了，會錯成一個會通過驗證的樣子」，才是這個邊界真正要防
# 的風險。
# =============================================================================
test_boundary2_stray_dash_after_heading_is_unfixable() {
  local rejected="$TMP/b2-in" out="$TMP/b2-out"
  mkdir -p "$rejected" "$out"
  cat > "$rejected/react-clusters-3.md" <<'EOF'
---
id: react-stray-dash-after-heading
layer: react
frameworks: ["react@>=18"]
severity_default: HIGH
## 觸發訊號
diff 裡出現這個模式。

## 判準
這是判準內容，說明為什麼這個模式有問題。

## 嚴重度
CRITICAL：最嚴重的情況
HIGH：次嚴重的情況
MEDIUM：影響較小的情況

## 反例（不該報）
這種情況不該報。

---
上面這條 --- 只是「反例」章節裡用來分隔兩段話的內文分隔線，出現在第一個
## 之後，不是 frontmatter 的收尾——這份檔案的 frontmatter 其實從來沒有
真正收尾過。

## 出處
- https://github.com/example/repo/pull/1#discussion_r1
- https://github.com/example/repo/pull/2#discussion_r2
- https://github.com/example/repo/pull/3#discussion_r3
EOF
  local before; before="$(cat "$rejected/react-clusters-3.md")"

  local out_msg; out_msg="$(run_repair "$rejected" "$out" 2>"$TMP/b2.err")"
  has "印出仍不通過 1" "$out_msg" "仍不通過 1"
  has "印出救回 0" "$out_msg" "救回 0"
  eq "沒有搬到 out" "0" "$(count_md "$out")"
  has "訊息用專屬代碼標記格式整個壞掉" "$(cat "$TMP/b2.err")" "HEADING_BEFORE_CLOSER"
  local after; after="$(cat "$rejected/react-clusters-3.md")"
  eq "原始檔案沒被動過" "$before" "$after"
}

# =============================================================================
# 邊界 3：完全沒有 ## ——沒有插入點，不可修復。
# =============================================================================
test_boundary3_no_heading_at_all_is_unfixable() {
  local rejected="$TMP/b3-in" out="$TMP/b3-out"
  mkdir -p "$rejected" "$out"
  cat > "$rejected/rails-clusters-3.md" <<'EOF'
---
id: rails-no-heading
layer: rails
frameworks: ["rails@>=7"]
severity_default: MEDIUM
模型輸出在這裡斷掉了，沒有任何 ## 章節標題。
EOF
  local out_msg; out_msg="$(run_repair "$rejected" "$out" 2>"$TMP/b3.err")"
  has "印出仍不通過 1" "$out_msg" "仍不通過 1"
  eq "沒有搬到 out" "0" "$(count_md "$out")"
  has "訊息用專屬代碼標記沒有插入點" "$(cat "$TMP/b3.err")" "NO_HEADING"
  eq "原始檔案還在 _rejected" "1" \
    "$([ -f "$rejected/rails-clusters-3.md" ] && echo 1 || echo 0)"
}

# =============================================================================
# 邊界 4：第一行不是 ---，不是 frontmatter 格式，不可修復。
# =============================================================================
test_boundary4_first_line_not_dash_is_unfixable() {
  local rejected="$TMP/b4-in" out="$TMP/b4-out"
  mkdir -p "$rejected" "$out"
  cat > "$rejected/vue-clusters-4.md" <<'EOF'
這個 cluster 沒有共同的 code review 主題，我不會輸出這條規則。
EOF
  local out_msg; out_msg="$(run_repair "$rejected" "$out" 2>"$TMP/b4.err")"
  has "印出仍不通過 1" "$out_msg" "仍不通過 1"
  eq "沒有搬到 out" "0" "$(count_md "$out")"
  has "訊息用專屬代碼標記第一行不是 ---" "$(cat "$TMP/b4.err")" "FIRST_LINE_NOT_DASH"
  eq "原始檔案還在 _rejected" "1" \
    "$([ -f "$rejected/vue-clusters-4.md" ] && echo 1 || echo 0)"
}

# =============================================================================
# 邊界 5：殘缺輸出（實測真實 _rejected 有這種：模型輸出被截斷，整個檔案只剩
# 一行 URL）。不可修復——直接對應真實的 react-clusters-2.md 那種形狀。
# =============================================================================
test_boundary5_truncated_url_only_output_is_unfixable() {
  local rejected="$TMP/b5-in" out="$TMP/b5-out"
  mkdir -p "$rejected" "$out"
  cat > "$rejected/react-clusters-5.md" <<'EOF'
- https://github.com/example/repo/pull/1#discussion_r1
- https://github.com/example/repo/pull/2#discussion_r2
EOF
  local out_msg; out_msg="$(run_repair "$rejected" "$out" 2>"$TMP/b5.err")"
  has "印出仍不通過 1" "$out_msg" "仍不通過 1"
  eq "沒有搬到 out" "0" "$(count_md "$out")"
  eq "原始檔案還在 _rejected（不可修復，留在原地）" "1" \
    "$([ -f "$rejected/react-clusters-5.md" ] && echo 1 || echo 0)"
}

# =============================================================================
# 邊界 7：<out> 已經有同名檔——要報錯或跳過，不能靜默覆蓋別的規則。
# =============================================================================
test_boundary7_existing_dest_file_is_not_overwritten() {
  local rejected="$TMP/b7-in" out="$TMP/b7-out"
  mkdir -p "$rejected" "$out"
  printf 'SENTINEL：這是既有的、已經驗證過的規則檔，不該被覆蓋\n' \
    > "$out/common-conflict-target.md"

  {
    printf '%s\n' '---' 'id: common-conflict-target' 'layer: common' \
      'frameworks: ["*"]' 'severity_default: LOW' ''
    write_valid_body
  } > "$rejected/common-clusters-77.md"

  local out_msg; out_msg="$(run_repair "$rejected" "$out" 2>"$TMP/b7.err")"
  local rc=$?
  eq "退出碼非 0（撞名是要被注意到的異常）" "1" "$rc"
  has "印出仍不通過 1" "$out_msg" "仍不通過 1"
  has "訊息用專屬 token 報撞名，不是靜默跳過" "$(cat "$TMP/b7.err")" "RULE_REPAIR_CONFLICT"
  eq "既有的規則檔內容完全沒被覆蓋" "SENTINEL：這是既有的、已經驗證過的規則檔，不該被覆蓋" \
    "$(cat "$out/common-conflict-target.md")"
  eq "撞名的來源檔案還留在 _rejected（沒有被搬走、也沒有被刪除）" "1" \
    "$([ -f "$rejected/common-clusters-77.md" ] && echo 1 || echo 0)"
}

# =============================================================================
# 混合批次：驗證彙總數字同時算對「救回」與「仍不通過」，不是只在單一檔案的
# 情境下才準——呼應 brief 的「一次報所有問題」精神，這裡是「一次處理整批」。
# =============================================================================
test_mixed_batch_summary_counts_are_correct() {
  local rejected="$TMP/mix-in" out="$TMP/mix-out"
  mkdir -p "$rejected" "$out"

  {
    printf '%s\n' '---' 'id: common-mix-fixable-1' 'layer: common' \
      'frameworks: ["*"]' 'severity_default: HIGH' ''
    write_valid_body
  } > "$rejected/common-clusters-1.md"

  {
    printf '%s\n' '---' 'id: common-mix-fixable-2' 'layer: common' \
      'frameworks: ["*"]' 'severity_default: HIGH' ''
    write_valid_body
  } > "$rejected/common-clusters-2.md"

  printf '只是一段散文，沒有 frontmatter，不可修復。\n' \
    > "$rejected/common-clusters-3.md"

  local out_msg; out_msg="$(run_repair "$rejected" "$out" 2>"$TMP/mix.err")"
  has "印出救回 2" "$out_msg" "救回 2"
  has "印出仍不通過 1" "$out_msg" "仍不通過 1"
  eq "out 目錄有兩個檔案" "2" "$(count_md "$out")"
  eq "_rejected 只剩不可修復的那個" "1" "$(count_md "$rejected")"
}

# =============================================================================
# 用法檢查：缺目錄參數要報錯、退出非 0，不能悄悄當成 0 個檔案處理完就結束。
# =============================================================================
test_missing_rejected_dir_fails_loudly() {
  local out="$TMP/usage-out"
  mkdir -p "$out"
  local out_msg rc
  out_msg="$(bash "$MRA_DIR/scripts/rule-repair.sh" --rejected "$TMP/does-not-exist" --out "$out" 2>&1)"
  rc=$?
  [ "$rc" -ne 0 ] && ok "缺 rejected 目錄時退出碼非 0" || fail "應該退出非 0"
  has "印出用法" "$out_msg" "用法"
}

# =============================================================================
# 靜態檢查：這個專案已經為「2>/dev/null 吞掉診斷」付過四次代價，直接鎖住
# scripts/rule-repair.sh 裡不會出現這個模式，防止之後有人手滑加回去。
# =============================================================================
test_script_never_discards_stderr_with_dev_null() {
  lacks "scripts/rule-repair.sh 沒有 2>/dev/null" \
    "$(cat "$MRA_DIR/scripts/rule-repair.sh")" "2>/dev/null"
}

test_basic_missing_closer_gets_rescued
test_boundary1_already_closed_stays_untouched_when_still_invalid
test_boundary1_already_closed_and_actually_valid_is_rescued_unmodified
test_boundary2_stray_dash_after_heading_is_unfixable
test_boundary3_no_heading_at_all_is_unfixable
test_boundary4_first_line_not_dash_is_unfixable
test_boundary5_truncated_url_only_output_is_unfixable
test_boundary7_existing_dest_file_is_not_overwritten
test_mixed_batch_summary_counts_are_correct
test_missing_rejected_dir_fails_loudly
test_script_never_discards_stderr_with_dev_null

echo "---"; echo "Passed: $pass"; echo "Failed: $errors"
exit $((errors > 0 ? 1 : 0))
