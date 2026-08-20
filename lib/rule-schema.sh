#!/usr/bin/env bash
# canonical 規則檔的解析與驗證。兩條萃取路線的產出都要通過這裡，否則最後
# 比較的可能是格式差異而不是規則品質。
#
# 不用 YAML 解析器：frontmatter 只有四個純量欄位，用 awk 抓比拉一個相依
# 進來划算。frameworks 是陣列但只當字串傳遞，不需要解析內容。
#
# 驗證一次報所有問題，不是遇到第一個就 return：萃取階段一次產幾十個檔，
# 一次看到全部問題比修一個跑一次快得多。
#
# 依賴 lib/corpus-targets.sh 的 corpus_layers()（合法 layer 清單的唯一
# 來源，不在這裡重複寫死）。呼叫端（bin/mra.sh 透過 MRA_LIBS、或獨立腳本）
# 要負責先 source 它。

RULE_VALID_SEVERITIES="CRITICAL HIGH MEDIUM LOW"
RULE_REQUIRED_FIELDS="id layer frameworks severity_default"
RULE_REQUIRED_SECTIONS="觸發訊號 判準 嚴重度 反例 出處"
RULE_MIN_SOURCES=3

# rule_frontmatter <file> — 印出 frontmatter 的 YAML 部分（不含 --- 界線）。
rule_frontmatter() {
  local f="$1"
  awk 'NR==1 && $0 != "---" { exit 1 }
       NR>1 && $0 == "---" { exit 0 }
       NR>1 { print }' "$f"
}

# rule_field <file> <key> — 印出單一 frontmatter 欄位的值；缺欄位回空字串、
# 退出碼 1。用 sub() 砍掉 $0 裡「key: 」的前綴，而不是取 $2，這樣值本身
# 含冒號（例如未來可能出現的 URL 值）不會被截斷。
rule_field() {
  local f="$1" key="$2" val
  val="$(rule_frontmatter "$f" | RULE_KEY="$key" awk -F': *' \
    '$1 == ENVIRON["RULE_KEY"] { sub(/^[^:]*: */, ""); print; found=1 } END { exit !found }')"
  local rc=$?
  printf '%s' "$val"
  return $rc
}

# rule_section <file> <章節標題> — 印出該 ## 章節的內容（不含標題行本身、
# 不含下一個 ## 章節）。
#
# 用「開頭符合」而不是「整行完全相等」比對標題：規則檔的章節標題常帶括號
# 註解（fixture 裡是「## 反例（不該報）」），呼叫端只會傳短名字
# 「反例」。整行相等會讓合格 fixture 本身被判定「反例」章節不存在。
rule_section() {
  local f="$1" title="$2"
  RULE_TITLE="## $title" awk '
    !inside && index($0, ENVIRON["RULE_TITLE"]) == 1 { inside=1; next }
    inside && /^## / { exit }
    inside { print }' "$f"
}

# rule_source_count <file> — 印出「出處」章節裡的 URL 數量。
# `|| true`：grep -c 在 0 筆匹配時退出碼是 1，呼叫端（rule_validate、以及
# 任何在 set -e 環境下 source 這支 lib 的腳本）不該因為「數字剛好是 0」
# 這個合法結果就被打斷。
rule_source_count() {
  rule_section "$1" 出處 | grep -cE 'https?://' || true
}

# rule_validate <file> — 合格回 0；不合格印出每個問題到 stderr 並回 1。
# 一次收集所有問題再回報，不遇到第一個就 return——萃取階段一次會產幾十個
# 規則檔，一次看到全部問題比修一個跑一次快得多。
rule_validate() {
  local f="$1" problems=0
  [ -f "$f" ] || { printf 'RULE_FILE_MISSING\t%s\n' "$f" >&2; return 1; }

  local base; base="$(basename "$f" .md)"

  local key
  for key in $RULE_REQUIRED_FIELDS; do
    if ! rule_field "$f" "$key" >/dev/null; then
      printf 'RULE_FIELD_MISSING\t%s\t%s\n' "$f" "$key" >&2
      problems=$((problems + 1))
    fi
  done

  local id; id="$(rule_field "$f" id)"
  if [ -n "$id" ] && [ "$id" != "$base" ]; then
    printf 'RULE_ID_MISMATCH\t%s\tid=%s 但檔名是 %s，兩者必須一致\n' "$f" "$id" "$base" >&2
    problems=$((problems + 1))
  fi

  local layer; layer="$(rule_field "$f" layer)"
  if [ -n "$layer" ] && ! corpus_layers | grep -qx "$layer"; then
    printf 'RULE_LAYER_INVALID\t%s\t%s 不在合法清單：%s\n' \
      "$f" "$layer" "$(corpus_layers | tr '\n' ' ')" >&2
    problems=$((problems + 1))
  fi

  local sev; sev="$(rule_field "$f" severity_default)"
  if [ -n "$sev" ] && ! printf '%s\n' $RULE_VALID_SEVERITIES | grep -qx "$sev"; then
    printf 'RULE_SEVERITY_INVALID\t%s\t%s 不在合法清單：%s\n' \
      "$f" "$sev" "$RULE_VALID_SEVERITIES" >&2
    problems=$((problems + 1))
  fi

  local section
  for section in $RULE_REQUIRED_SECTIONS; do
    if [ -z "$(rule_section "$f" "$section" | tr -d '[:space:]')" ]; then
      printf 'RULE_SECTION_MISSING\t%s\t%s\n' "$f" "$section" >&2
      problems=$((problems + 1))
    fi
  done

  local n; n="$(rule_source_count "$f")"
  if [ "$n" -lt "$RULE_MIN_SOURCES" ]; then
    printf 'RULE_SOURCES_TOO_FEW\t%s\t出處只有 %s 則，至少要 %s 則\n' \
      "$f" "$n" "$RULE_MIN_SOURCES" >&2
    problems=$((problems + 1))
  fi

  [ "$problems" -eq 0 ]
}
