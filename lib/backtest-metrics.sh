#!/usr/bin/env bash
# 回測的三個指標。
#
# 命中的定義是「同一個檔案，且行號差在容差內」。用容差是因為 review 指的行與
# 缺陷實際所在的行常差幾行，逐行嚴格比對會把命中判成漏抓。沒給容差引數時預設
# 是 5——這是校準過的值，不是隨手挑的，改動要連帶改 tests/test_backtest_metrics.sh
# 裡釘住預設值的斷言。
#
# unmatched_rate 不是誤報率。review 找到基準集沒收錄的真問題也會計入，所以只能
# 用來看新舊規則之間的趨勢，不能當成絕對的誤報數字。
#
# 一個 comment 在整次比對裡最多只能被一個 expected finding 認領：expected
# findings 先照 (path, line) 排序處理，每筆各自從「還沒被認領」的 comment 池
# 挑最近的一筆，挑中後從池子移除。這解決兩個問題：
#   1. unmatched 判斷用 comment 在原始陣列裡的「位置」(matched_idx)，不是
#      line 值——兩個不同檔案剛好行號一樣時，line 值比對會把不相干的那個也
#      誤判成命中，位置比對不會。
#   2. 兩個 expected finding 的容差窗重疊、搶同一顆 comment 時，只有先處理
#      的那個(排序後較前面)能拿到；輸給搶奪、沒有其他候選的那個算漏抓，不會
#      讓同一顆 comment 同時墊高兩個 expected 的命中數，也不會讓 severity_rate
#      的分母被重複計算。
#   排序鍵選 (path, line) 而不是原始陣列順序，是要讓「誰先搶到」不隨呼叫端
#   餵資料的順序而變，同一組 expected/review 不管原始陣列怎麼排都得出同一個
#   結果。
#
# 同一個 expected 有多筆候選在容差窗內打平(距離相同)時，選原始 review.comments
# 陣列裡排比較前面的那一筆——靠的是 jq sort_by 本身的排序穩定性，不是刻意另外
# 寫規則；已用 fixture 釘住這個行為，不能因為候選陣列被反著餵就選到不同的那筆。
backtest_match() {
  local review="$1" expected="$2" tol="${3:-5}"
  jq -n --argjson review "$review" --argjson expected "$expected" --argjson tol "$tol" '
    ($review.comments | to_entries) as $rc
    | ($expected | to_entries | sort_by([.value.path, .value.line])) as $se
    | (reduce $se[] as $item (
         {claimed: [], out: []};
         . as $acc
         | ( [ $rc[]
               | select(.value.path == $item.value.path)
               | select((.value.line - $item.value.line) | fabs <= $tol)
               | select(([.key] | inside($acc.claimed)) | not) ]
             | sort_by((.value.line - $item.value.line) | fabs) ) as $cands
         | ($cands[0]) as $pick
         | if $pick == null then
             $acc + { out: ($acc.out + [ { orig_idx: $item.key, expected: $item.value,
                                            matched: null, matched_idx: null } ]) }
           else
             { claimed: ($acc.claimed + [$pick.key]),
               out: ($acc.out + [ { orig_idx: $item.key, expected: $item.value,
                                     matched: $pick.value, matched_idx: $pick.key } ]) }
           end
       )
     ) as $result
    | ($result.out | sort_by(.orig_idx) | map({expected, matched, matched_idx}))'
}

backtest_metrics() {
  local matches="$1" review="$2"
  jq -n --argjson m "$matches" --argjson r "$review" '
    ($m | length) as $et
    | ([$m[] | select(.matched == null)] | length) as $missed
    | ([$m[] | select(.matched != null)]) as $hits
    | ($r.comments | length) as $ct
    | ([$hits[].matched_idx]) as $claimed_idx
    | ($r.comments | to_entries) as $indexed
    | ([$indexed[] | select(([.key] | inside($claimed_idx)) | not)] | length) as $unmatched
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
