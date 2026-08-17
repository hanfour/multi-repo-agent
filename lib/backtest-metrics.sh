#!/usr/bin/env bash
# 回測的三個指標。
#
# 命中的定義是「同一個檔案，且行號差在容差內」。用容差是因為 review 指的行與
# 缺陷實際所在的行常差幾行，逐行嚴格比對會把命中判成漏抓。
#
# unmatched_rate 不是誤報率。review 找到基準集沒收錄的真問題也會計入，所以只能
# 用來看新舊規則之間的趨勢，不能當成絕對的誤報數字。

backtest_match() {
  local review="$1" expected="$2" tol="${3:-5}"
  jq -n --argjson review "$review" --argjson expected "$expected" --argjson tol "$tol" '
    [ $expected[] as $e
      | { expected: $e,
          matched: ( [ $review.comments[]
                       | select(.path == $e.path)
                       | select((.line - $e.line) | fabs <= $tol) ]
                     | sort_by((.line - $e.line) | fabs) | .[0] // null ) } ]'
}

backtest_metrics() {
  local matches="$1" review="$2"
  jq -n --argjson m "$matches" --argjson r "$review" '
    ($m | length) as $et
    | ([$m[] | select(.matched == null)] | length) as $missed
    | ([$m[] | select(.matched != null)]) as $hits
    | ($r.comments | length) as $ct
    | ([$hits[].matched.line] | unique) as $hit_lines
    | ([$r.comments[] | select([.line] | inside($hit_lines) | not)] | length) as $unmatched
    | ([$hits[] | select(.matched.severity == .expected.severity)] | length) as $agree
    | def round2: (. * 100 | round) / 100;
      { expected_total: $et,
        missed: $missed,
        miss_rate: (if $et == 0 then 0 else ($missed / $et) | round2 end),
        comments_total: $ct,
        unmatched: $unmatched,
        unmatched_rate: (if $ct == 0 then 0 else ($unmatched / $ct) | round2 end),
        severity_agree: $agree,
        severity_rate: (if ($hits | length) == 0 then 0 else ($agree / ($hits | length)) | round2 end) }'
}
