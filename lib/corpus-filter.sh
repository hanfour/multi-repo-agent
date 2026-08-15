#!/usr/bin/env bash
# 語料篩選五步。每步是讀 stdin 寫 stdout 的獨立函式，可單獨測試也可串成管線。
#
# 第 1 步不是可選項：vuejs/core 近 300 則 review comment 有 186 則是 CodeRabbit，
# 不濾掉的話學到的是另一個 AI reviewer 的平均水準。

# shellcheck disable=SC2016
_CORPUS_JQ_DEFS='
# GitHub 帳號被刪除後，該筆 review comment 的 .user 會是 null。真實資料上有：
# nestjs/nest 的 2,121 筆裡有 3 筆。沒有 has_login 這層守衛的話，is_bot 對 null 做
# ascii_downcase 會讓整個 jq 以 `explode input must be a string` 中止，整個 repo 的
# 語料一筆都拿不到。
def has_login:
  (.user | type) == "object" and ((.user.login | type) == "string");
def is_bot:
  (.user.login | ascii_downcase) as $u
  | ($u | test("\\[bot\\]$"))
    or (["coderabbitai","copilot","dependabot","github-actions","renovate"] | any(. == $u));
def senior:
  .author_association as $a
  | ($a == "MEMBER" or $a == "OWNER" or $a == "COLLABORATOR");
def quality:
  (.body | length) > 150
  or (.in_reply_to_id != null)
  or (.reactions.total_count > 0);
def has_prose:
  (.body | gsub("```suggestion(.|\\n)*?```"; "") | gsub("\\s"; "") | length) >= 20;
'
# 註：不要改成 gsub("```suggestion.*?```"; ""; "s")。jq 的 "s" flag 不會讓 `.`
# 匹配換行，suggestion 區塊會整段留著，只有 suggestion 沒有說明的意見就濾不掉。

# 第一步同時濾掉 bot 與「無法歸屬」的意見（帳號已刪除，.user 是 null）。留存欄位
# 沿用 n1_nobot 這個名字，改名會牽動 Task 4 的表頭與 Task 6 的測試，不值得。
corpus_filter_bots()    { jq "$_CORPUS_JQ_DEFS [ .[] | select(has_login and (is_bot | not)) ]"; }
corpus_filter_senior()  { jq "$_CORPUS_JQ_DEFS [ .[] | select(senior) ]"; }
corpus_filter_quality() { jq "$_CORPUS_JQ_DEFS [ .[] | select(quality) ]"; }
corpus_filter_prose()   { jq "$_CORPUS_JQ_DEFS [ .[] | select(has_prose) ]"; }

# diff_hunk 是整份語料最有價值的欄位：它讓每則意見自帶被批評的那段程式碼。
corpus_project() {
  local repo="$1" layer="$2"
  jq --arg repo "$repo" --arg layer "$layer" '[ .[] | {
    id,
    repo: $repo,
    layer: $layer,
    reviewer: .user.login,
    association: .author_association,
    path,
    diff_hunk,
    body,
    in_reply_to: .in_reply_to_id,
    reactions: .reactions.total_count,
    url: .html_url,
    created_at
  } ]'
}

# stdout：最終陣列。stderr：一行 TSV 留存數，讓呼叫端能記錄每一步濾掉多少。
# 任何一階段失敗就回 1，不得回 0。下游 scripts/build-corpus.sh 要靠這個退出碼決定
# 該 repo 算不算失敗；吃掉錯誤的話，輸入壞掉或 GitHub schema 改變會變成「篩完 0 筆、
# 一切正常」，正是這份設計要避免的 false-green。
#
# 兩個 bash 細節，不要「整理」掉：
#   1. `local s0 s1 …` 必須單獨一行宣告，指派另外寫。寫成 `local s1="$(...)"` 的話，
#      $? 拿到的是 local 自己的退出碼（永遠 0），命令替換的失敗會被吞掉。
#   2. jq 解析失敗的退出碼是 5，不是 1，所以用 `|| return 1` 判斷而不是比對數值。
corpus_filter_all() {
  local repo="$1" layer="$2"
  local s0 s1 s2 s3 s4
  s0="$(cat)"

  # 先驗輸入。壞掉的輸入要當場失敗，而不是讓四個 jq 各噴一次錯之後回 0。
  if ! printf '%s' "$s0" | jq -e 'type == "array"' >/dev/null 2>&1; then
    printf 'FILTER_INPUT_INVALID\t%s\n' "$repo" >&2
    return 1
  fi

  s1="$(printf '%s' "$s0" | corpus_filter_bots)" \
    || { printf 'FILTER_STAGE_FAILED\t%s\tbots\n' "$repo" >&2; return 1; }
  s2="$(printf '%s' "$s1" | corpus_filter_senior)" \
    || { printf 'FILTER_STAGE_FAILED\t%s\tsenior\n' "$repo" >&2; return 1; }
  s3="$(printf '%s' "$s2" | corpus_filter_quality)" \
    || { printf 'FILTER_STAGE_FAILED\t%s\tquality\n' "$repo" >&2; return 1; }
  s4="$(printf '%s' "$s3" | corpus_filter_prose)" \
    || { printf 'FILTER_STAGE_FAILED\t%s\tprose\n' "$repo" >&2; return 1; }
  printf 'RETENTION\t%s\t%s\t%s\t%s\t%s\t%s\n' "$repo" \
    "$(printf '%s' "$s0" | jq 'length')" \
    "$(printf '%s' "$s1" | jq 'length')" \
    "$(printf '%s' "$s2" | jq 'length')" \
    "$(printf '%s' "$s3" | jq 'length')" \
    "$(printf '%s' "$s4" | jq 'length')" >&2
  printf '%s' "$s4" | corpus_project "$repo" "$layer"
}
