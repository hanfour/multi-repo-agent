#!/usr/bin/env bash
# 語料篩選五步。每步是讀 stdin 寫 stdout 的獨立函式，可單獨測試也可串成管線。
#
# 第 1 步不是可選項：vuejs/core 近 300 則 review comment 有 186 則是 CodeRabbit，
# 不濾掉的話學到的是另一個 AI reviewer 的平均水準。

# shellcheck disable=SC2016
_CORPUS_JQ_DEFS='
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

corpus_filter_bots()    { jq "$_CORPUS_JQ_DEFS [ .[] | select(is_bot | not) ]"; }
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
corpus_filter_all() {
  local repo="$1" layer="$2"
  local s0 s1 s2 s3 s4
  s0="$(cat)"
  s1="$(printf '%s' "$s0" | corpus_filter_bots)"
  s2="$(printf '%s' "$s1" | corpus_filter_senior)"
  s3="$(printf '%s' "$s2" | corpus_filter_quality)"
  s4="$(printf '%s' "$s3" | corpus_filter_prose)"
  printf 'RETENTION\t%s\t%s\t%s\t%s\t%s\t%s\n' "$repo" \
    "$(printf '%s' "$s0" | jq 'length')" \
    "$(printf '%s' "$s1" | jq 'length')" \
    "$(printf '%s' "$s2" | jq 'length')" \
    "$(printf '%s' "$s3" | jq 'length')" \
    "$(printf '%s' "$s4" | jq 'length')" >&2
  printf '%s' "$s4" | corpus_project "$repo" "$layer"
}
