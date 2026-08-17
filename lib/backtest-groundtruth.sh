#!/usr/bin/env bash
# 回測基準集的 ground truth 候選判定。
#
# 判定：PR 合併後 N 天內，有 commit type 是 fix/hotfix/bug（message 開頭的
# conventional commit 前綴，如 `fix(scope):`）改到同一檔案，
# 且行號區間與 PR 的改動重疊。
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
  # fix/hotfix/bug 比對限定在 message 開頭的 conventional commit type
  # （如 `fix(scope):`、`fix:`），不是整句任意位置的子字串比對——
  # 否則像 "feat(w): not a fix" 這種句子裡帶 "fix" 字樣、但類型其實是 feat
  # 的 commit 會被誤判為候選。
  gh api "repos/$repo/commits?since=$merged&until=$until&per_page=100" 2>/dev/null \
    | jq --arg own "$own" --arg pr "$pr" '
      [ .[]
        | select(.sha != $own)
        | select(.commit.message | test("^(fix|hotfix|bug)\\b"; "i"))
        | select(.commit.message | test("#" + $pr + "\\b") | not)
        | {sha: .sha, message: (.commit.message | split("\n")[0])} ]'
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
