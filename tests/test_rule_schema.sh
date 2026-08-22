#!/usr/bin/env bash
# canonical 規則檔的 schema 與驗證 (lib/rule-schema.sh)。
#
# 兩條萃取路線（TF-IDF 分群、finding 分類）的產出都要通過這一套驗證，否則
# 最後比較的可能是格式差異而不是規則品質。這支測試因此不只驗「合格 fixture
# 通過」，還逐一驗每種不合格的形狀都能被抓到，而且驗證一次要報所有問題，
# 不是遇到第一個就停——萃取階段一次會產幾十個檔，一次看到全部問題比修一個
# 跑一次快得多。
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

TMP="$(mktemp -d "${TMPDIR:-/tmp}/rule-schema-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

FIX="$MRA_DIR/tests/fixtures/rules"

test_valid_fixture_passes() {
  rule_validate "$FIX/valid-example.md" 2>"$TMP/err" && ok "合格 fixture 通過" \
    || fail "合格 fixture 應該通過：$(cat "$TMP/err")"
}

test_missing_frontmatter_field() {
  sed '/^severity_default:/d' "$FIX/valid-example.md" > "$TMP/no-sev.md"
  local out; out="$(rule_validate "$TMP/no-sev.md" 2>&1)"
  local rc=$?
  [ "$rc" -ne 0 ] && ok "缺 severity_default 不通過" || fail "應該不通過"
  has "訊息指名缺哪個欄位" "$out" "severity_default"
}

test_missing_section() {
  # 砍掉「反例」整段
  awk '/^## 反例/{skip=1} /^## 出處/{skip=0} !skip' "$FIX/valid-example.md" > "$TMP/no-counter.md"
  local out; out="$(rule_validate "$TMP/no-counter.md" 2>&1)"
  local rc=$?
  [ "$rc" -ne 0 ] && ok "缺反例章節不通過" || fail "應該不通過"
  has "訊息指名缺哪個章節" "$out" "反例"
}

test_source_count_below_three() {
  # 只留兩則出處
  sed '/discussion_r100003/d' "$FIX/valid-example.md" > "$TMP/two-src.md"
  local out; out="$(rule_validate "$TMP/two-src.md" 2>&1)"
  local rc=$?
  [ "$rc" -ne 0 ] && ok "出處只有兩則不通過" || fail "應該不通過"
  has "訊息說出處不足" "$out" "出處"
  eq "rule_source_count 算出 2" "2" "$(rule_source_count "$TMP/two-src.md")"
}

test_severity_default_must_be_known() {
  sed 's/^severity_default: HIGH/severity_default: URGENT/' "$FIX/valid-example.md" > "$TMP/bad-sev.md"
  local out; out="$(rule_validate "$TMP/bad-sev.md" 2>&1)"
  local rc=$?
  [ "$rc" -ne 0 ] && ok "不認得的 severity 不通過" || fail "應該不通過"
  has "訊息指名不合法的值" "$out" "URGENT"
}

test_id_must_match_filename() {
  cp "$FIX/valid-example.md" "$TMP/wrong-name.md"
  local out; out="$(rule_validate "$TMP/wrong-name.md" 2>&1)"
  local rc=$?
  [ "$rc" -ne 0 ] && ok "id 與檔名不符不通過" || fail "應該不通過"
  has "訊息說明 id 與檔名要一致" "$out" "wrong-name"
}

test_layer_must_be_known() {
  sed 's/^layer: nestjs/layer: golang/' "$FIX/valid-example.md" > "$TMP/bad-layer.md"
  local out; out="$(rule_validate "$TMP/bad-layer.md" 2>&1)"
  local rc=$?
  [ "$rc" -ne 0 ] && ok "不認得的 layer 不通過" || fail "應該不通過"
  has "訊息列出合法的 layer" "$out" "nestjs"
}

test_section_extraction() {
  local body; body="$(rule_section "$FIX/valid-example.md" "判準")"
  has "判準章節抓得到內容" "$body" "request-scoped provider"
  lacks "判準章節不含下一節的內容" "$body" "CRITICAL："
}

# 每個問題各報一次，不要遇到第一個就中止 —— 萃取階段一次會產幾十個檔，
# 一次看到全部問題比修一個跑一次快得多。
test_reports_all_problems_at_once() {
  sed -e '/^severity_default:/d' -e '/discussion_r100003/d' \
    "$FIX/valid-example.md" > "$TMP/two-problems.md"
  local out; out="$(rule_validate "$TMP/two-problems.md" 2>&1)"
  has "同時報 severity_default" "$out" "severity_default"
  has "同時報出處不足" "$out" "出處"
}

# 額外案例：不在 brief 裡，但補上以驗證 rule_field / rule_frontmatter 的
# 基本取值行為，是後續 rule_render_block 依賴的介面。
test_rule_field_extracts_scalar() {
  eq "rule_field 取得 id" "valid-example" "$(rule_field "$FIX/valid-example.md" id)"
  eq "rule_field 取得 layer" "nestjs" "$(rule_field "$FIX/valid-example.md" layer)"
  eq "rule_field 取得 severity_default" "HIGH" "$(rule_field "$FIX/valid-example.md" severity_default)"
}

test_rule_field_missing_key_returns_empty_and_nonzero() {
  local out; out="$(rule_field "$FIX/valid-example.md" no_such_field)"
  local rc=$?
  eq "缺欄位印出空字串" "" "$out"
  [ "$rc" -eq 1 ] && ok "缺欄位退出碼是 1" || fail "應該回傳退出碼 1，得到 $rc"
}

# --- Re-review 找到的 4 個 Critical：都是手動構造的畸形／邊界輸入，不是
# 推測。每一個都在拿掉對應修法後單獨跑過、確認會轉紅——過程與訊息記在
# task-2-report.md，這裡只留最終版斷言。

# Critical 1：欄位有 key 但值是空字串（例如 `id:`），rule_field 判定為
# 「找到了」（rc=0），舊版因此完全逃過「缺欄位」迴圈，也因為 [ -n "$id" ]
# 這個 guard 為假而跳過後續合法性檢查——實測整份檔案 rule_validate 回傳 0
# (PASS)。修法：必填欄位迴圈同時檢查退出碼與值是否為空字串。
test_empty_value_field_counts_as_missing() {
  sed 's/^id: valid-example/id:/' "$FIX/valid-example.md" > "$TMP/empty-id.md"
  local out; out="$(rule_validate "$TMP/empty-id.md" 2>&1)"
  local rc=$?
  [ "$rc" -ne 0 ] && ok "id 有 key 但值是空字串時不通過" || fail "應該不通過"
  has "訊息把空值 id 當成缺欄位" "$out" "RULE_FIELD_MISSING"
  printf '%s\n' "$out" | grep -qE $'\tid$' \
    && ok "訊息指名的欄位剛好是 id（不是欄位名裡含 id 的其他東西）" \
    || fail "訊息裡沒有以 tab+id 結尾的行：$out"
  lacks "空值 id 不該再額外觸發 id/檔名不符（同一個根因不要報兩次語意錯亂的問題）" \
    "$out" "RULE_ID_MISMATCH"
}

# 四個必填欄位都受這個 bug 影響，一次全部驗證覆蓋到、且各自獨立算一個問題
# （驗證「一次報所有問題」跟這個修法一起運作正常）。
test_all_empty_required_fields_are_each_flagged() {
  sed -e 's/^id: valid-example/id:/' \
      -e 's/^layer: nestjs/layer:/' \
      -e 's#^frameworks:.*#frameworks:#' \
      -e 's/^severity_default: HIGH/severity_default:/' \
      "$FIX/valid-example.md" > "$TMP/all-empty.md"
  local out; out="$(rule_validate "$TMP/all-empty.md" 2>&1)"
  local rc=$?
  [ "$rc" -ne 0 ] && ok "四個欄位全部只有 key 沒有值時不通過" || fail "應該不通過"
  local n; n="$(printf '%s\n' "$out" | grep -c 'RULE_FIELD_MISSING')"
  eq "四個空值欄位各自報一次 RULE_FIELD_MISSING" "4" "$n"
}

# Critical 2：frontmatter 缺收尾 --- 時，rule_frontmatter 舊版會把整個檔案
# 剩餘內容（含所有章節本文）當成 frontmatter 印出、exit 0、不報錯。實測
# rule_validate 回傳 0 (PASS)，現在能矇混過關純粹是因為章節內容剛好沒有
# 出現 key: value 形狀的行。修法：rule_frontmatter 用 found 旗標偵測有沒有
# 真的看到收尾 ---，rule_validate 用自己的 token RULE_FRONTMATTER_UNTERMINATED
# 報出來。
#
# id 刻意改成跟檔名一致（不是沿用 valid-example 這個舊 id）：這批畸形輸入
# fixture 如果檔名跟內部 id 不一致，會額外巧合觸發 RULE_ID_MISMATCH，讓
# 「這個檔案只有一個問題」這種斷言變得無法乾淨地驗證（前幾輪已經在報告裡
# 記錄過同一個坑）。這裡刻意讓 id 對得上檔名，這樣輸出裡除了
# RULE_FRONTMATTER_UNTERMINATED 之外不該再有任何別的問題——包括 re-review
# 找到的 pipefail bug：rule_field 內部用管線接 rule_frontmatter 的輸出時，
# `set -o pipefail` 底下 rule_frontmatter 自己的 exit 1（未終結）會蓋掉
# 內層 awk「找到欄位」的 exit 0，害 rule_field 印出正確的值、卻回傳退出碼
# 1（宣稱找不到）。連帶後果是必填欄位迴圈把 id/layer/frameworks/
# severity_default 全部誤報成 RULE_FIELD_MISSING——即使這四個欄位在檔案裡
# 都寫得好好的。這會把萃取路線的 agent 導向錯的修復方向（去補根本沒缺的
# 欄位，而不是補收尾的 ---），所以除了「有報 RULE_FRONTMATTER_UNTERMINATED」
# 之外，還要斷言「沒有報 RULE_FIELD_MISSING」，且訊息應該只有那一行。
test_unterminated_frontmatter_is_rejected() {
  # 只拿掉第二個 ---（收尾界線），保留開頭那個；id 改成跟檔名一致。
  sed 's/^id: valid-example/id: unterminated/' "$FIX/valid-example.md" \
    | awk '!( $0 == "---" && ++c == 2 )' > "$TMP/unterminated.md"
  local closer_count; closer_count="$(grep -c -- '^---$' "$TMP/unterminated.md")"
  eq "fixture 準備正確：只剩一個 ---（開頭那個）" "1" "$closer_count"

  local out; out="$(rule_validate "$TMP/unterminated.md" 2>&1)"
  local rc=$?
  [ "$rc" -ne 0 ] && ok "缺收尾 --- 的檔案不通過" || fail "應該不通過"
  has "訊息用專屬 token 指出缺收尾 ---" "$out" "RULE_FRONTMATTER_UNTERMINATED"
  lacks "不該把明明寫得好好的欄位誤報成缺欄位" "$out" "RULE_FIELD_MISSING"
  local n; n="$(printf '%s\n' "$out" | grep -c .)"
  eq "只報一個問題（缺收尾 ---），不該有其他連帶誤報" "1" "$n"
}

# 直接在 rule_field 這一層鎖住 re-review 實測到的確切症狀：對缺收尾 --- 的
# 檔案呼叫 rule_field id，值確實抓到了，退出碼卻宣稱找不到。這支測試不透過
# rule_validate，直接驗證 rule_field 本身的回傳值與退出碼要一致——避免以後
# 又有人在 rule_field 內部重新接回一段管線，把 rule_frontmatter 的退出碼
# 透過 pipefail 滲回來。
test_rule_field_not_corrupted_by_unterminated_frontmatter() {
  sed 's/^id: valid-example/id: unterminated-field/' "$FIX/valid-example.md" \
    | awk '!( $0 == "---" && ++c == 2 )' > "$TMP/unterminated-field.md"

  local val; val="$(rule_field "$TMP/unterminated-field.md" id)"
  local rc=$?
  eq "值確實抓到了（frontmatter 未終結不影響掃描到的欄位內容）" "unterminated-field" "$val"
  [ "$rc" -eq 0 ] && ok "退出碼跟值一致：找到了就是 0，不該被 rule_frontmatter 自己的 1 透過 pipefail 蓋過去" \
    || fail "退出碼應該是 0，得到 ${rc}（值有抓到但退出碼卻說找不到，就是 pipefail 污染的症狀）"
}

# Critical 3：rule_source_count 舊版用 grep -cE 算「相符的行數」，同一行塞
# 兩個 URL（同一個 PR 的多則 review comment 很自然會這樣寫）只算 1 則。
# 實測三則出處擠成兩行會被誤判「只有 2 則」而擋下——這道關卡的目的是防止
# 樣本太少的幻覺規則，結果反而誤殺樣本足夠的規則。修法：grep -oE 印出每個
# 相符子字串（一個 URL 一行）再 wc -l，數 URL 出現次數不是行數。
test_multiple_urls_on_one_line_are_all_counted() {
  sed 's/^id: valid-example/id: two-urls-one-line/' "$FIX/valid-example.md" | awk '
    /discussion_r100001/ { line1 = $0; getline line2; print line1 " " line2; next }
    { print }
  ' > "$TMP/two-urls-one-line.md"

  local url_lines; url_lines="$(rule_section "$TMP/two-urls-one-line.md" 出處 | grep -c 'https\?://')"
  eq "fixture 準備正確：三則出處只佔兩行" "2" "$url_lines"

  eq "rule_source_count 數出 3 個 URL，即使只佔兩行" "3" "$(rule_source_count "$TMP/two-urls-one-line.md")"

  rule_validate "$TMP/two-urls-one-line.md" 2>"$TMP/two-urls-err" \
    && ok "三則出處擠成兩行仍然通過，不會被誤判成出處不足" \
    || fail "不該因為出處擠成兩行就不通過：$(cat "$TMP/two-urls-err")"
}

# Critical 4：rule_section 的前綴比對沒錨定邊界，「## 判準」這個前綴符合
# 也會命中「## 判準補充」這種同前綴但其實是別的章節的標題。實測構造一個
# 「## 判準補充」出現在真正的「## 判準」之前，rule_section <file> 判準
# 回傳的是判準補充的內容，而且因為抓到的內容非空，rule_validate 完全不會
# 發現、仍然回傳 0 (PASS)——這個最麻煩，因為 Task 6 的 rule_render_block
# 直接呼叫這個函式產出要注入 persona 的最終內容，會把錯的文字渲染進去，
# 且沒有任何錯誤訊號。修法：比對加錨定邊界，前綴後面必須接空白、半形／
# 全形括號，或行尾才算數。
test_section_prefix_match_is_boundary_anchored() {
  cat > "$TMP/decoy-section.md" <<'EOF'
---
id: decoy-section
layer: nestjs
frameworks: ["@nestjs/core@>=9"]
severity_default: HIGH
---
## 觸發訊號
diff 裡出現 `@Injectable({ scope: Scope.REQUEST })`，或 request-scoped provider
被注入進 singleton service。

## 判準補充
這是偽裝章節，標題跟「判準」同前綴，內容是誘餌，不該被 rule_section 抓到。

## 判準
這才是真正的判準內容，request-scoped provider 被 singleton 注入時會把整條
依賴鏈提升成 request scope。

## 嚴重度
CRITICAL：被提升的鏈上有連線池或外部資源 handle
HIGH：被提升的鏈上有具狀態的 service
MEDIUM：只影響無狀態的 helper

## 反例（不該報）
provider 本來就宣告成 request scope 且鏈上全部都是 request scope，
那是刻意的設計，不要報。

## 出處
- https://github.com/nestjs/nest/pull/1001#discussion_r100001
- https://github.com/nestjs/nest/pull/1002#discussion_r100002
- https://github.com/nestjs/nest/pull/1003#discussion_r100003
EOF

  local body; body="$(rule_section "$TMP/decoy-section.md" 判準)"
  has "抓到的是真正判準章節的內容" "$body" "這才是真正的判準內容"
  lacks "不該被同前綴的偽裝章節劫持" "$body" "偽裝章節"

  rule_validate "$TMP/decoy-section.md" 2>"$TMP/decoy-err" \
    && ok "有同前綴偽裝章節時，合格檔案仍然通過" \
    || fail "不該被偽裝章節誤導成不通過：$(cat "$TMP/decoy-err")"
}

# Minor（re-review 第二輪順手做）：boundary_ok 沒把 \r 列為合法邊界字元，
# CRLF 結尾的合法章節標題（例如「## 判準\r\n」）會被判邊界不合格，導致
# rule_section 抓不到內容。直接測 rule_section，不透過 rule_validate：
# 一份整份 CRLF 的規則檔會先在 frontmatter 的 --- 相等比對被擋下來（那兩行
# 會變成 "---\r"，跟純 "---" 不相等），沒辦法乾淨地隔離出 boundary_ok 本身
# 認不認得 \r 這件事；rule_section 直接掃檔案找 ## 標題，不需要合法
# frontmatter，可以單獨測。
test_boundary_ok_accepts_crlf_heading() {
  printf '## 觸發訊號\r\n前一段內容。\r\n## 判準\r\n這是 CRLF 結尾的判準內容。\r\n## 嚴重度\r\n' \
    > "$TMP/crlf-section.md"
  local body; body="$(rule_section "$TMP/crlf-section.md" 判準)"
  has "CRLF 結尾的章節標題仍然被正確辨識為邊界，抓得到內容" "$body" "這是 CRLF 結尾的判準內容"
  lacks "不該把下一節（嚴重度）的內容也吃進來" "$body" "嚴重度"
}

# Minor：RULE_LAYER_INVALID 訊息尾端不該有多餘空白（corpus_layers | tr '\n' ' '
# 會把最後一個換行也轉成空格）。順手一起修。
test_layer_invalid_message_has_no_trailing_space() {
  sed 's/^layer: nestjs/layer: golang/' "$FIX/valid-example.md" > "$TMP/bad-layer-trim.md"
  local out; out="$(rule_validate "$TMP/bad-layer-trim.md" 2>&1)"
  local line; line="$(printf '%s\n' "$out" | grep RULE_LAYER_INVALID)"
  case "$line" in
    *" ") fail "RULE_LAYER_INVALID 訊息結尾多了一個空白：[$line]" ;;
    *)    ok "RULE_LAYER_INVALID 訊息結尾沒有多餘空白" ;;
  esac
}

# --- id_is_safe()：兩條萃取管線（scripts/extract-rules-tfidf.sh、
# scripts/rule-repair.sh）共用的路徑穿越防線（re-review Critical 1）。id
# 會直接拼進檔案路徑（<out>/<id>.md），來源是未經清洗的模型輸出，只放行
# 英數字、連字號、底線。直接測函式本身的定義域，不透過任一條呼叫端腳本——
# 四個畸形輸入（../、單一 /、空字串、含換行）都要被拒絕，合法格式要放行。

test_id_is_safe_rejects_path_traversal() {
  if id_is_safe "../../../etc/passwd"; then
    fail "含 ../ 的 id 應該被拒絕，卻被判定為安全"
  else
    ok "含 ../ 的 id 被拒絕"
  fi
}

test_id_is_safe_rejects_single_slash() {
  if id_is_safe "nestjs/evil"; then
    fail "含 / 的 id 應該被拒絕，卻被判定為安全"
  else
    ok "含 / 的 id 被拒絕"
  fi
}

test_id_is_safe_rejects_empty_string() {
  if id_is_safe ""; then
    fail "空 id 應該被拒絕，卻被判定為安全"
  else
    ok "空 id 被拒絕"
  fi
}

test_id_is_safe_rejects_embedded_newline() {
  if id_is_safe "$(printf 'nestjs-valid\nrule')"; then
    fail "含換行的 id 應該被拒絕，卻被判定為安全"
  else
    ok "含換行的 id 被拒絕"
  fi
}

test_id_is_safe_accepts_well_formed_id() {
  if id_is_safe "nestjs-request-scoped-provider-in-singleton"; then
    ok "合法格式（英數字/連字號）的 id 被放行"
  else
    fail "合法格式的 id 不該被拒絕"
  fi
}

# grep -q 會在配到的當下退出，producer 還沒寫完就吃到 SIGPIPE 回 141。呼叫端
# 開著 pipefail 時，`! producer | grep -q` 會把這個 141 判成「沒配到」。2026-08-22
# 那一輪回測就是這樣掛的：81 個 layer=common 的規則檔隨機中了 2 個，訊息還
# 自相矛盾（「common 不在合法清單：common nestjs rails react vue」），整輪回測
# 因為 RULES_INVALID 直接中止。
#
# 下面三支把 producer 的輸出撐到超過 pipe buffer（64KB），讓 SIGPIPE 必然發生，
# 不靠 sleep 賭時序。合法值放第一行，grep 最早退出、競態視窗最大。
_big_tail() { seq 1 20000; }   # 約 108KB，穩定超過 64KB pipe buffer

test_layer_check_survives_early_grep_exit() {
  sed -e 's/^layer: nestjs$/layer: common/' -e 's/^id: valid-example$/id: layer-common/' \
    "$FIX/valid-example.md" > "$TMP/layer-common.md"
  corpus_layers() { printf 'common\n'; _big_tail; }
  local out rc
  out="$(rule_validate "$TMP/layer-common.md" 2>&1)"; rc=$?
  unset -f corpus_layers
  source "$MRA_DIR/lib/corpus-targets.sh"
  if [ "$rc" -eq 0 ]; then
    ok "producer 提早收到 SIGPIPE 時 layer=common 仍判為合法"
  else
    fail "layer=common 被誤判成不合法（SIGPIPE 競態）：${out:0:160}"
  fi
}

test_layer_check_still_rejects_unknown_layer_under_sigpipe() {
  sed -e 's/^layer: nestjs$/layer: kotlin/' -e 's/^id: valid-example$/id: layer-bad/' \
    "$FIX/valid-example.md" > "$TMP/layer-bad.md"
  corpus_layers() { printf 'common\n'; _big_tail; }
  local out; out="$(rule_validate "$TMP/layer-bad.md" 2>&1)"
  unset -f corpus_layers
  source "$MRA_DIR/lib/corpus-targets.sh"
  has "同一條路徑下不合法的 layer 仍被擋" "$out" "RULE_LAYER_INVALID"
}

test_severity_check_survives_early_grep_exit() {
  sed -e 's/^severity_default: HIGH$/severity_default: CRITICAL/' \
      -e 's/^id: valid-example$/id: sev-first/' \
    "$FIX/valid-example.md" > "$TMP/sev-first.md"
  local saved="$RULE_VALID_SEVERITIES"
  RULE_VALID_SEVERITIES="CRITICAL $(_big_tail | tr '\n' ' ')"
  local out rc
  out="$(rule_validate "$TMP/sev-first.md" 2>&1)"; rc=$?
  RULE_VALID_SEVERITIES="$saved"
  if [ "$rc" -eq 0 ]; then
    ok "producer 提早收到 SIGPIPE 時 severity=CRITICAL 仍判為合法"
  else
    fail "severity=CRITICAL 被誤判成不合法（SIGPIPE 競態）：${out:0:160}"
  fi
}

test_valid_fixture_passes
test_missing_frontmatter_field
test_missing_section
test_source_count_below_three
test_severity_default_must_be_known
test_id_must_match_filename
test_layer_must_be_known
test_section_extraction
test_reports_all_problems_at_once
test_rule_field_extracts_scalar
test_rule_field_missing_key_returns_empty_and_nonzero
test_empty_value_field_counts_as_missing
test_all_empty_required_fields_are_each_flagged
test_unterminated_frontmatter_is_rejected
test_rule_field_not_corrupted_by_unterminated_frontmatter
test_multiple_urls_on_one_line_are_all_counted
test_section_prefix_match_is_boundary_anchored
test_boundary_ok_accepts_crlf_heading
test_layer_invalid_message_has_no_trailing_space
test_id_is_safe_rejects_path_traversal
test_id_is_safe_rejects_single_slash
test_id_is_safe_rejects_empty_string
test_id_is_safe_rejects_embedded_newline
test_id_is_safe_accepts_well_formed_id
test_layer_check_survives_early_grep_exit
test_layer_check_still_rejects_unknown_layer_under_sigpipe
test_severity_check_survives_early_grep_exit

echo "---"; echo "Passed: $pass"; echo "Failed: $errors"
exit $((errors > 0 ? 1 : 0))
