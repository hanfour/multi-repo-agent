#!/usr/bin/env bash
# 回測基準集的 ground truth 候選判定。
#
# 判定：PR 合併後 N 天內，有 commit message 標題（第一行）含 fix/hotfix/bugfix/bug
# 或 修正/修復/修掉（任意位置的子字串比對，中英文都算）的 commit 改到同一檔案，
# 且行號區間與 PR 的改動重疊。
#
# 標題子字串比對而非錨定在標題開頭：這個團隊不是每個 fix commit 都寫
# `fix(scope):`，常見的還有 `FIN-264 fix: ...`、`ITP-3045 fix: ...`、
# `Fix team split ...`、`[Bugfix] ...`、`[ODM] 上刊通報 修正轉檔` 這類前面
# 帶 ticket 編號、大寫字首、或中文描述的寫法，fix 詞彙落在句子中間。錨定在
# 開頭會漏掉這類真 fix commit（實測 acme/rails-app-1 300 筆真實 commit，錨定比
# 子字串比對少命中超過一半）。
#
# 中英文詞彙都要收：只比對英文 fix/hotfix/bug，300 筆裡有 52 筆「完全沒出現
# 任何英文 fix 字樣、只用中文寫」的真 fix commit 會被漏掉（例：「修正 function
# 不存在問題」），佔真 fix commit 的四成。基準集的用途是拿去測別的工具漏抓
# 率，分母本身就漏 4 成，量出來的數字沒有意義。
#
# 只看第一行、不看整個 message body：GitHub squash merge 會把每個子 commit
# 的訊息都摺進 body。一個標題叫「雜項調整」的 batch PR，body 裡隨便一行
# `fix rubocop`／`fix rspec` 這種 lint／測試收尾就會讓整個 PR 被誤收——那是
# 雜訊，不是真正在修的東西，而且這個 batch PR 通常跟候選要問的那個 PR 毫無
# 關係。標題才是這次 commit 對自己下的結論。
#
# 兩種誤判的代價不對稱：誤收的候選還要通過行號重疊比對、最後仍有人工確認
# 這一關；誤刪的候選則永遠不會出現，之後也補不回來。候選命中率本來就只有
# 12.5%，母體已經很窄，寧可多留、不能漏掉。
#
# 兩個必要的排除，否則會把 PR 自己算成「修自己的 commit」：
#   1. 該 PR 的 merge_commit_sha
#   2. message 裡帶 `#<PR 編號>` 的 commit
# 團隊用 `fix(scope):` 當 PR 標題慣例，所以 PR 自己的 merge commit 一定長得像
# 一個 fix commit。
#
# 這個判定只產出「候選」。檔案層級的重疊實測太寬（acme/rails-app-1 近 40 個 PR 至少
# 9 個命中，多數是日常改動），行號層級收緊後仍需人工確認，見 Task 4。

# 不用 gh api 的 --jq：測試用的 PATH shim 回傳的是未經處理的原始 GitHub API
# JSON（貼近真實回應形狀），並不會執行 --jq 帶的過濾器。過濾/改名一律自己 pipe
# 給 jq 做，這樣同一段邏輯在 shim 與正式環境下行為一致，也才測得到。
backtest_merged_prs() {
  local repo="$1" limit="${2:-100}"
  gh api "repos/$repo/pulls?state=closed&per_page=$limit&sort=updated&direction=desc" 2>/dev/null \
    | jq '[ .[] | select(.merged_at != null)
            | {n: .number, merged_at: .merged_at, merge_commit_sha: .merge_commit_sha} ]'
}

backtest_window_end() {
  local start="$1" days="${2:-14}"
  python3 -c "
import datetime, sys
d = datetime.datetime.strptime(sys.argv[1], '%Y-%m-%dT%H:%M:%SZ')
print((d + datetime.timedelta(days=int(sys.argv[2]))).strftime('%Y-%m-%dT%H:%M:%SZ'))
" "$start" "$days"
}

backtest_fix_commits() {
  local repo="$1" pr="$2" merged="$3" own="$4" days="${5:-14}"
  local until; until="$(backtest_window_end "$merged" "$days")"
  # gh api 的 --jq 不接受 --arg，所以這裡 pipe 給 jq 而不是用 --jq。
  # fix 詞彙（中英文，見檔頭註解的理由）只比對標題（第一行），不看整個
  # message body——這兩個改動要一起上：只限定標題、不擴詞彙，中文 fix
  # commit 還是漏掉；只擴詞彙、不限定標題，squash body 的雜訊還是混進來。
  # `Merge ` 開頭的合併 commit 額外排除——像 `Merge pull request #4873 from
  # acme/misc-20260513-fix-seq` 這種標題，分支名裡常帶 "fix" 字樣，子字串
  # 比對會誤收，但這只是合併雜訊，不是真正的 fix commit。
  gh api "repos/$repo/commits?since=$merged&until=$until&per_page=100" 2>/dev/null \
    | jq --arg own "$own" --arg pr "$pr" '
      [ .[]
        | (.commit.message | split("\n")[0]) as $title
        | select(.sha != $own)
        | select($title | test("fix|hotfix|bugfix|bug|修正|修復|修掉"; "i"))
        | select($title | test("^Merge "; "i") | not)
        | select(.commit.message | test("#" + $pr + "\\b") | not)
        | {sha: .sha, message: $title} ]'
}

# 內部用：把 [{filename, patch}] 轉成 {"<path>": [[起,迄], ...]}
_backtest_ranges_from_files() {
  local files_json="$1"
  local out='{}' path patch ranges
  while IFS= read -r path; do
    [[ -z "$path" ]] && continue
    patch="$(printf '%s' "$files_json" | jq -r --arg p "$path" '.[] | select(.filename == $p) | .patch // ""')"
    ranges="$(printf '%s\n' "$patch" | backtest_hunks_of \
      | awk 'NF == 2 { printf "[%s,%s],", $1, $2 }' | sed 's/,$//')"
    [[ -z "$ranges" ]] && continue
    out="$(printf '%s' "$out" | jq --arg p "$path" --argjson r "[$ranges]" '. + {($p): $r}')"
  done < <(printf '%s' "$files_json" | jq -r '.[].filename')
  printf '%s' "$out"
}

backtest_pr_ranges() {
  local repo="$1" pr="$2" files
  files="$(gh api "repos/$repo/pulls/$pr/files?per_page=100" 2>/dev/null)" || return 1
  _backtest_ranges_from_files "$files"
}

backtest_commit_ranges() {
  local repo="$1" sha="$2"
  local files
  # 同上，不用 --jq，改成自己 pipe 給 jq 取出 .files。
  files="$(gh api "repos/$repo/commits/$sha" 2>/dev/null | jq '.files')" || return 1
  _backtest_ranges_from_files "$files"
}

# 邊界刻意用 <=（inclusive）而不是 <：fix hunk 從 PR 新增區間的最後一行接著往下寫,
# 是很常見的真實形狀（在 PR 剛加的那段結尾繼續補東西）。若邊界改成 exclusive,
# 這種候選會憑空消失——而漏掉的候選補不回來,跟 lib/backtest-hunks.sh 的
# backtest_ranges_overlap 用同一個判準，是同一件事的兩份保險。
backtest_overlap() {
  local a="$1" b="$2"
  jq -n --argjson a "$a" --argjson b "$b" '
    [ ($a | to_entries[]) as $pa
      | ($b[$pa.key] // []) as $bl
      | $pa.value[] as $ra
      | $bl[] as $rb
      | select($ra[0] <= $rb[1] and $rb[0] <= $ra[1])
      | {path: $pa.key, pr_range: $ra, fix_range: $rb} ]'
}
