#!/usr/bin/env bash
# 基準集的人工確認工具。
#
# 候選是「PR 合併後有 fix commit 改到重疊行號」，這只是相關，不是因果。實測
# acme/rails-app-1 近 40 個 PR 用檔案層級判定有 9 個命中，其中多數是日常改動。所以每一筆
# 都要人看過，判斷那個 fix 是不是在修這個 PR 引入的問題。
#
# candidates.json 不進 git、沒有第二份副本，裡面的 confirmed／expected_findings
# 是花掉人工審查成本才填的，寫壞了就是永久遺失。所以每一次寫入都先落到同目錄的
# .tmp、驗過 jq 與 mv 兩邊的退出碼才算數；任何一邊失敗都保留原本的 candidates.json
# 不動，並各自用自己的 token 回報是哪一步失敗（不能把兩種失敗混報成同一句話，
# 不然沒辦法分辨是「這次寫的內容有問題」還是「搬檔案這步本身失敗」）。
set -uo pipefail

BENCH_DIR="${MRA_BENCHMARK_DIR:-$HOME/.cache/mra-review-benchmark}"
C="$BENCH_DIR/candidates.json"
[[ -f "$C" ]] || { echo "找不到 $C，先跑 scripts/build-benchmark.sh" >&2; exit 1; }

# 寫入一律走這裡：jq 算出新內容先落到 .tmp，驗過退出碼才 mv promote 進正式檔名，
# mv 也要驗退出碼。任何一步失敗都不動 $C，只清掉沒搬成功的 .tmp。
#
# $1：錯誤訊息裡要說的動作（例如「寫入 confirmed」），不含 token 前綴。
# $2 之後：整段傳給 jq 的參數（含 filter 本身）。
_write() {
  local desc="$1"; shift
  local tmp="$C.tmp"
  if ! jq "$@" "$C" > "$tmp"; then
    echo "WRITE_FAILED：${desc}失敗，$C 未變動" >&2
    rm -f "$tmp"
    return 1
  fi
  if ! mv "$tmp" "$C"; then
    echo "PROMOTE_FAILED：${desc}失敗，$C 未變動" >&2
    rm -f "$tmp"
    return 1
  fi
  return 0
}

_has_pr() {
  local n
  n="$(jq --argjson p "$1" '[.[] | select(.pr == $p)] | length' "$C")" || return 1
  [[ "$n" -gt 0 ]]
}

case "${1:---next}" in
  --status)
    jq -r '
      "未確認 \([.[] | select(.confirmed == null)] | length)"
      + " / 已確認 \([.[] | select(.confirmed != null)] | length)"
      + " / 確認為缺陷 \([.[] | select(.confirmed == true)] | length)"' "$C"
    ;;

  --next)
    # 取候選集裡「最舊」未確認的一筆：不是重新用 merged_at 排序，而是照
    # candidates.json 本身的陣列順序取第一筆。candidates.json 是逐次
    # build-benchmark.sh 合併累積出來的，陣列順序本身就是候選被發現、
    # 排進待審佇列的先後順序；改用 merged_at 排序等於用 PR 自己合併的時間
    # 去覆蓋佇列順序，兩者不是同一件事——一個候選可能很早就被發現排進佇列，
    # 它對應的 PR 卻合併得比較晚，用 merged_at 排序會讓它被排到後面，跟
    # 「先發現先審」的佇列語意矛盾。
    item="$(jq -c '[.[] | select(.confirmed == null)] | .[0] // empty' "$C")"
    if [[ -z "$item" ]]; then echo "沒有待確認的候選，確認完成"; exit 0; fi
    repo="$(printf '%s' "$item" | jq -r '.repo')"
    pr="$(printf '%s' "$item" | jq -r '.pr')"
    echo "PR      https://github.com/$repo/pull/$pr"
    echo "合併於  $(printf '%s' "$item" | jq -r '.merged_at')"
    printf '%s' "$item" | jq -r --arg repo "$repo" '
      .fix_commits[]
      | "fix     https://github.com/\($repo)/commit/\(.sha)\n        \(.message)",
        (.overlaps[] | "        重疊 \(.path)  PR \(.pr_range[0])-\(.pr_range[1])  fix \(.fix_range[0])-\(.fix_range[1])")'
    echo
    echo "判斷：這個 fix 是在修這個 PR 引入的缺陷嗎？"
    echo "  是 → scripts/review-benchmark.sh --set $pr true"
    echo "       再用 --add $pr <path> <line> <severity> <當初該抓到什麼> 記下期望的發現"
    echo "  否 → scripts/review-benchmark.sh --set $pr false"
    ;;

  --set)
    pr="$2"; val="$3"
    [[ "$pr" =~ ^[0-9]+$ ]] || { echo "pr 必須是數字：$pr" >&2; exit 1; }
    [[ "$val" == "true" || "$val" == "false" ]] || { echo "值必須是 true 或 false" >&2; exit 1; }
    _has_pr "$pr" || { echo "候選中沒有 PR $pr" >&2; exit 1; }
    _write "寫入 PR $pr 的 confirmed" \
      --argjson p "$pr" --argjson v "$val" \
      'map(if .pr == $p then .confirmed = $v else . end)' || exit 1
    echo "PR $pr → confirmed=$val"
    ;;

  --add)
    pr="$2"; path="$3"; line="$4"; sev="$5"; note="$6"
    [[ "$pr" =~ ^[0-9]+$ ]] || { echo "pr 必須是數字：$pr" >&2; exit 1; }
    [[ -n "$path" ]] || { echo "path 不能是空字串" >&2; exit 1; }
    [[ "$line" =~ ^[0-9]+$ && "$line" -ge 1 ]] || { echo "line 必須是 >= 1 的整數：$line" >&2; exit 1; }
    case "$sev" in CRITICAL|HIGH|MEDIUM|LOW) ;; *) echo "severity 必須是 CRITICAL/HIGH/MEDIUM/LOW" >&2; exit 1 ;; esac
    [[ -n "$note" ]] || { echo "note 不能是空字串" >&2; exit 1; }
    _has_pr "$pr" || { echo "候選中沒有 PR $pr" >&2; exit 1; }
    _write "追加 PR $pr 的 finding" \
      --argjson p "$pr" --arg path "$path" --argjson line "$line" --arg sev "$sev" --arg note "$note" \
      'map(if .pr == $p
           then .expected_findings += [{path: $path, line: $line, severity: $sev, note: $note}]
           else . end)' || exit 1
    echo "PR $pr 追加 finding：$path:$line [$sev]"
    ;;

  -h|--help)
    echo "用法: review-benchmark.sh [--next | --status | --set <pr> <true|false> | --add <pr> <path> <line> <severity> <note>]"
    ;;
  *) echo "未知參數：$1" >&2; exit 1 ;;
esac
