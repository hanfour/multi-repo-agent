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
#
# 候選集的鍵是 (repo, pr) 兩個欄位一起組，不是單獨的 pr——build-benchmark.sh
# 合併候選時就是照這個鍵走，同一個 PR 編號在不同 repo 各自有一列是常態。這支
# 工具的每一筆查找／寫入都要照同一個鍵走，只用 pr 配對會把決定寫到別的 repo
# 的列上，是這支工具第一輪 review 抓到的 Critical。
set -uo pipefail

BENCH_DIR="${MRA_BENCHMARK_DIR:-$HOME/.cache/mra-review-benchmark}"
C="$BENCH_DIR/candidates.json"
# $C 後面接全形標點會被 bash 的識別字詞法一起吃掉、變成找不存在的變數名稱，
# 在 zh_TW.UTF-8 語系下會直接炸成「C�: 未綁定的變數」——本來要診斷問題的
# 那行訊息本身變成新的問題。一定要用 ${C} 把邊界明確標出來擋掉。
[[ -f "$C" ]] || { echo "找不到 ${C}，先跑 scripts/build-benchmark.sh" >&2; exit 1; }

# 寫入一律走這裡：jq 算出新內容先落到 .tmp，驗過退出碼才 mv promote 進正式檔名，
# mv 也要驗退出碼。任何一步失敗都不動 ${C}，只清掉沒搬成功的 .tmp。
#
# $1：錯誤訊息裡要說的動作（例如「寫入 confirmed」），不含 token 前綴。
# $2 之後：整段傳給 jq 的參數（含 filter 本身）。
_write() {
  local desc="$1"; shift
  local tmp="$C.tmp"
  if ! jq "$@" "$C" > "$tmp"; then
    echo "WRITE_FAILED：${desc}失敗，${C} 未變動" >&2
    rm -f "$tmp"
    return 1
  fi
  if ! mv "$tmp" "$C"; then
    echo "PROMOTE_FAILED：${desc}失敗，${C} 未變動" >&2
    rm -f "$tmp"
    return 1
  fi
  return 0
}

# 決定 --set／--add 要動哪一列。有給 --repo 就直接照 (repo, pr) 比對是否存在；
# 沒給的話看候選集裡這個 pr 編號對應到幾個不同的 repo——剛好一個就自動選用，
# 兩個以上一定要使用者用 --repo 明確指定，不猜：猜錯就是把決定寫到別的 repo
# 的列上，而且沒有任何訊號會告訴使用者猜錯了。
#
# 成功時把選定的 repo 印到 stdout（唯一輸出），呼叫端用 command substitution
# 接；失敗時的診斷訊息一律走 stderr，不會被 command substitution 吃掉。
_resolve_repo() {
  local pr="$1" given="$2"
  if [[ -n "$given" ]]; then
    local n
    if ! n="$(jq --argjson p "$pr" --arg r "$given" \
                 '[.[] | select(.pr == $p and .repo == $r)] | length' "$C")"; then
      echo "READ_FAILED：查找 ${given}#${pr} 失敗" >&2
      return 1
    fi
    [[ "$n" -gt 0 ]] || { echo "候選中沒有 ${given}#${pr}" >&2; return 1; }
    printf '%s' "$given"
    return 0
  fi

  local repos_json
  if ! repos_json="$(jq -c --argjson p "$pr" '[.[] | select(.pr == $p) | .repo] | unique' "$C")"; then
    echo "READ_FAILED：查找 PR ${pr} 失敗" >&2
    return 1
  fi
  local n_repos
  n_repos="$(printf '%s' "$repos_json" | jq 'length')"
  case "$n_repos" in
    0) echo "候選中沒有 PR ${pr}" >&2; return 1 ;;
    1) printf '%s' "$repos_json" | jq -r '.[0]'; return 0 ;;
    *)
      echo "PR ${pr} 同時存在於多個 repo，請用 --repo 指定：" >&2
      printf '%s' "$repos_json" | jq -r '.[]' | sed 's/^/  /' >&2
      return 1
      ;;
  esac
}

# 選項解析迴圈裡「消耗一個值」的動作（例如 --repo 要接著讀 $2）一定要先確認
# 那個值真的存在，不能無條件 shift 2。使用者把 --repo 打成輸入的最後一個
# token（後面沒接值就送出）時，直接讀 $2 在 set -u 底下會被 bash 自己的
# 「未綁定的變數」炸掉——這跟第一輪修過的 Critical 3（找不到檔案時的診斷
# 訊息本身炸掉）是同一種錯：讀一個可能不存在的位置參數卻沒先擋。上一輪
# 只補了那一處，這一輪在新寫的選項解析迴圈裡又出現了一次，所以抽成共用
# 函式，往後選項變多也不會每加一個就要記得補一次同樣的檢查。
#
# $1：選項名稱（只用來組錯誤訊息）。呼叫端要在 shift 2 之前呼叫，通不過
# 直接 exit，不回傳——選項缺值是使用者輸入本身有問題，沒有恢復的餘地。
_require_opt_value() {
  echo "用法：$1 需要接一個值" >&2
  exit 1
}

case "${1:---next}" in
  --status)
    if ! jq -r '
      "未確認 \([.[] | select(.confirmed == null)] | length)"
      + " / 已確認 \([.[] | select(.confirmed != null)] | length)"
      + " / 確認為缺陷 \([.[] | select(.confirmed == true)] | length)"
      + " / 未確認已有 finding \([.[] | select(.confirmed == null
                                              and (.expected_findings | length) > 0)] | length)"
    ' "$C"; then
      echo "READ_FAILED：讀取 ${C} 失敗" >&2
      exit 1
    fi
    ;;

  --next)
    # 取候選集裡「最舊」未確認的一筆：不是重新用 merged_at 排序，而是照
    # candidates.json 本身的陣列順序取第一筆。candidates.json 是逐次
    # build-benchmark.sh 合併累積出來的，陣列順序本身就是候選被發現、
    # 排進待審佇列的先後順序；改用 merged_at 排序等於用 PR 自己合併的時間
    # 去覆蓋佇列順序，兩者不是同一件事——一個候選可能很早就被發現排進佇列，
    # 它對應的 PR 卻合併得比較晚，用 merged_at 排序會讓它被排到後面，跟
    # 「先發現先審」的佇列語意矛盾。
    #
    # jq 失敗（candidates.json 損毀或讀不到）一定要跟「全部確認完」分開報：
    # 前者是「沒讀到」，後者是「讀到了、確認是空的」，兩種狀況混報會讓使用者
    # 把「工具壞了」誤讀成「審完了」。
    if ! item="$(jq -c '[.[] | select(.confirmed == null)] | .[0] // empty' "$C")"; then
      echo "READ_FAILED：讀取 ${C} 失敗，候選集可能已損毀" >&2
      exit 1
    fi
    if [[ -z "$item" ]]; then echo "沒有待確認的候選，確認完成"; exit 0; fi
    repo="$(printf '%s' "$item" | jq -r '.repo')"
    pr="$(printf '%s' "$item" | jq -r '.pr')"
    echo "repo    $repo"
    echo "PR      https://github.com/$repo/pull/$pr"
    echo "合併於  $(printf '%s' "$item" | jq -r '.merged_at')"
    printf '%s' "$item" | jq -r --arg repo "$repo" '
      .fix_commits[]
      | "fix     https://github.com/\($repo)/commit/\(.sha)\n        \(.message)",
        (.overlaps[] | "        重疊 \(.path)  PR \(.pr_range[0])-\(.pr_range[1])  fix \(.fix_range[0])-\(.fix_range[1])")'
    echo
    echo "判斷：這個 fix 是在修這個 PR 引入的缺陷嗎？"
    echo "  是 → scripts/review-benchmark.sh --set --repo $repo $pr true"
    echo "       再用 --add --repo $repo $pr <path> <line> <severity> <當初該抓到什麼> 記下期望的發現"
    echo "  否 → scripts/review-benchmark.sh --set --repo $repo $pr false"
    ;;

  --set)
    shift
    repo=""
    args=()
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --repo)
          [[ $# -ge 2 ]] || _require_opt_value "--repo"
          repo="$2"; shift 2 ;;
        *) args+=("$1"); shift ;;
      esac
    done
    pr="${args[0]:-}"; val="${args[1]:-}"
    [[ -n "$pr" && -n "$val" ]] || {
      echo "用法：--set [--repo <owner/name>] <pr> <true|false>" >&2; exit 1; }
    [[ "$pr" =~ ^[0-9]+$ ]] || { echo "pr 必須是數字：$pr" >&2; exit 1; }
    [[ "$val" == "true" || "$val" == "false" ]] || { echo "值必須是 true 或 false：$val" >&2; exit 1; }

    resolved="$(_resolve_repo "$pr" "$repo")" || exit 1

    # 覆蓋一筆已經確認過的決定不是不能做（人工看走眼、想改判斷都合理），但
    # 不能悄悄做：舊決定底下如果已經記了 expected_findings，這筆改動一結束
    # 那些 findings 就會掛在一列「現在判定不是缺陷」的候選底下，容易被誤讀
    # 成雜訊而順手清掉——所以一定要警告、列出還留著幾筆，讓使用者自己決定
    # 要不要清，工具本身絕對不動 expected_findings。
    if ! old="$(jq -r --argjson p "$pr" --arg r "$resolved" \
                   '.[] | select(.pr == $p and .repo == $r) | .confirmed' "$C")"; then
      echo "READ_FAILED：讀取 ${resolved}#${pr} 目前的 confirmed 失敗" >&2
      exit 1
    fi

    _write "寫入 ${resolved}#${pr} 的 confirmed" \
      --argjson p "$pr" --arg r "$resolved" --argjson v "$val" \
      'map(if .pr == $p and .repo == $r then .confirmed = $v else . end)' || exit 1

    if [[ "$old" != "null" && "$old" != "$val" ]]; then
      n_findings="$(jq --argjson p "$pr" --arg r "$resolved" \
        '[.[] | select(.pr == $p and .repo == $r) | .expected_findings[]] | length' "$C")"
      echo "警告：${resolved}#${pr} 的 confirmed 從 ${old} 改成 ${val}，原本已有 ${n_findings} 筆 expected_findings，沒有被清掉，需要的話自己刪" >&2
    fi
    echo "${resolved}#${pr} → confirmed=${val}"
    ;;

  --add)
    shift
    repo=""
    args=()
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --repo)
          [[ $# -ge 2 ]] || _require_opt_value "--repo"
          repo="$2"; shift 2 ;;
        *) args+=("$1"); shift ;;
      esac
    done
    pr="${args[0]:-}"; path="${args[1]:-}"; line="${args[2]:-}"; sev="${args[3]:-}"; note="${args[4]:-}"
    [[ -n "$pr" && -n "$path" && -n "$line" && -n "$sev" && -n "$note" ]] || {
      echo "用法：--add [--repo <owner/name>] <pr> <path> <line> <severity> <note>" >&2; exit 1; }
    [[ "$pr" =~ ^[0-9]+$ ]] || { echo "pr 必須是數字：$pr" >&2; exit 1; }
    [[ "$line" =~ ^[0-9]+$ && "$line" -ge 1 ]] || { echo "line 必須是 >= 1 的整數：$line" >&2; exit 1; }
    case "$sev" in CRITICAL|HIGH|MEDIUM|LOW) ;; *) echo "severity 必須是 CRITICAL/HIGH/MEDIUM/LOW：$sev" >&2; exit 1 ;; esac

    resolved="$(_resolve_repo "$pr" "$repo")" || exit 1

    # 行號落在 PR 沒改到的地方時警告。reviewer 讀的是 diff，那些行它看不到，
    # 標了等於保證漏抓，而且事後從 summary 完全看不出來。實測階段二的基準集
    # 54 條裡有 10 條是這樣。
    #
    # 只警告不擋：標註者有可能刻意要記一個 diff 外的位置（缺陷的根源在別處，
    # PR 只是暴露了它）。擋下來會讓那種情況無法記錄。查不到 patch 時（網路
    # 失敗、權限不足）也只是跳過這道檢查，不影響 --add 本身。
    # 同樣要分頁（見 lib/backtest-groundtruth.sh 的 backtest_pr_ranges）：未分頁
    # 時第 100 個之後的檔案在 patch 裡根本不存在，這道檢查會對每一條標在那些
    # 檔案上的 finding 誤報 LINE_OUTSIDE_DIFF。
    if _pr_files_raw="$(gh api --paginate --slurp "repos/${resolved}/pulls/${pr}/files?per_page=100" 2>/dev/null)" \
       && _pr_patch="$(printf '%s' "$_pr_files_raw" | jq 'add // []')"; then
      _in_diff="$(jq -r --arg p "$path" --argjson l "$line" '
        [.[] | select(.filename == $p) | .patch // ""] | .[0] // ""
        | [scan("@@ -[0-9]+(?:,[0-9]+)? \\+([0-9]+)(?:,([0-9]+))? @@")]
        | map({start: (.[0]|tonumber), len: ((.[1] // "1")|tonumber)})
        | map(select($l >= .start and $l <= (.start + .len - 1)))
        | length' <<<"$_pr_patch" 2>/dev/null)" || _in_diff=""
      if [[ "${_in_diff:-0}" == "0" ]]; then
        echo "LINE_OUTSIDE_DIFF：${path}:${line} 不在 ${resolved}#${pr} 改動到的行裡。reviewer 讀的是 diff，這一行它看不到，這條 finding 會保證漏抓。確認行號是不是該指向 PR 實際改動的位置" >&2
      fi
    fi

    _write "追加 ${resolved}#${pr} 的 finding" \
      --argjson p "$pr" --arg r "$resolved" --arg path "$path" --argjson line "$line" --arg sev "$sev" --arg note "$note" \
      'map(if .pr == $p and .repo == $r
           then .expected_findings += [{path: $path, line: $line, severity: $sev, note: $note}]
           else . end)' || exit 1
    echo "${resolved}#${pr} 追加 finding：${path}:${line} [${sev}]"
    ;;

  -h|--help)
    echo "用法: review-benchmark.sh [--next | --status |"
    echo "        --set [--repo <owner/name>] <pr> <true|false> |"
    echo "        --add [--repo <owner/name>] <pr> <path> <line> <severity> <note>]"
    echo "candidates.json 的鍵是 (repo, pr)；同一個 pr 編號出現在多個 repo 時"
    echo "必須用 --repo 指定，工具不會用猜的。"
    ;;
  *) echo "未知參數：$1" >&2; exit 1 ;;
esac
