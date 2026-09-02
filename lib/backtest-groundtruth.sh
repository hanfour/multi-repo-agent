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
#
# sort=created，不是 sort=updated（Ruling 27）：同一個指令在不同時間跑，
# updated 排序抓到的 PR 集合會不一樣。任何人在一個舊 PR 底下留言、改
# label、重新推送，都會把它推上「最近更新」的排序前段，擠掉原本該在窗口
# 內的另一個 PR。created_at 是 PR 建立當下就定死的時間戳，不會因為後續
# 活動而變動，同一個 --limit 在任何時間點重跑，抓到的都是同一批 PR。
#
# $until（可選，ISO 8601，例如 2026-08-01T00:00:00Z）：只收 created_at
# 早於這個時間點的 PR，嚴格小於（不含當下這一刻）。給階段四之後用：把
# 這一次抓候選集當下的時間點記下來，之後不管什麼時候重跑，只要 --limit
# 與 --until 都不變，抓到的 PR 集合就跟這一次完全一樣，不必知道確切的
# PR 編號範圍，只要凍住「當時看到的世界線」。沒給的話（預設）行為與現在
# 完全一致：不做這層過濾，抓到「現在最新建立的 N 筆」。
# $limit 直接進 per_page，而 GitHub 的 per_page 上限是 100：給 300 的話 API
# 靜默回 100 筆，呼叫端以為分母是 300、實際是 100，而且沒有任何訊號。這裡不
# 自動改成分頁去湊滿——分頁會把「最近建立的 N 筆」變成一個要抓好幾頁、燒額度
# 的操作，而目前的用法（每個 repo 取最近 100 個 PR）根本不需要。直接擋下來，
# 讓使用者知道上限在哪，比悄悄給一個比要求少的分母好。
#
# $since（可選，ISO 8601）：收 created_at 不早於這個時間點的全部 merged PR
# （>=，跟 until 的嚴格小於相對，兩個一起給就是左閉右開的區間）。這是給
# 「掃一年」用的：沒有 since 的路徑只抓一頁、永遠碰不到第 101 筆以後的 PR。
# 有 since 就逐頁翻（每頁 100 筆，$limit 不用），翻到「這一頁最後一筆的
# created_at 已早於 since」或「這一頁不滿 100 筆」為止；端點是新到舊排序，
# 所以停下來時再往後的頁全部都比 since 早。任何一頁抓不到就回非 0，不把抓
# 到一半的清單當完整結果。
backtest_merged_prs() {
  local repo="$1" limit="${2:-100}" until="${3:-}" since="${4:-}"
  case "$limit" in
    ''|*[!0-9]*|0)
      printf 'LIMIT_INVALID\t%s\t--limit 必須是 1 到 100 之間的整數\n' "$limit" >&2
      return 1 ;;
  esac
  if [ "$limit" -gt 100 ]; then
    printf 'LIMIT_TOO_LARGE\t%s\tGitHub 的 per_page 上限是 100，超過的部分會被靜默丟掉\n' \
      "$limit" >&2
    return 1
  fi
  local base="repos/$repo/pulls?state=closed&sort=created&direction=desc"
  local filter='[ .[] | select(.merged_at != null)
                      | select($until == "" or .created_at < $until)
                      | select($since == "" or .created_at >= $since)
                      | {n: .number, merged_at: .merged_at, merge_commit_sha: .merge_commit_sha} ]'
  if [ -z "$since" ]; then
    gh api "${base}&per_page=$limit" 2>/dev/null \
      | jq --arg until "$until" --arg since "$since" "$filter"
    return
  fi
  local page=1 all='[]' chunk n last
  while :; do
    chunk="$(gh api "${base}&per_page=100&page=$page" 2>/dev/null)" || return 1
    n="$(printf '%s' "$chunk" | jq 'length')" || return 1
    all="$(printf '%s\n%s' "$all" "$chunk" | jq -sc '.[0] + .[1]')" || return 1
    last="$(printf '%s' "$chunk" | jq -r '.[-1].created_at // ""')" || return 1
    if [ "$n" -lt 100 ] || [ -z "$last" ] || [[ "$last" < "$since" ]]; then
      break
    fi
    page=$((page + 1))
  done
  printf '%s' "$all" | jq --arg until "$until" --arg since "$since" "$filter"
}

backtest_window_end() {
  local start="$1" days="${2:-14}"
  python3 -c "
import datetime, sys
d = datetime.datetime.strptime(sys.argv[1], '%Y-%m-%dT%H:%M:%SZ')
print((d + datetime.timedelta(days=int(sys.argv[2]))).strftime('%Y-%m-%dT%H:%M:%SZ'))
" "$start" "$days"
}

# 已知限制，跟 scripts/run-backtest.sh 的 candidates_sha 有關（那支腳本另有人在改，
# 這裡只留紀錄）：candidates_sha 是對整份 candidates.json 取雜湊，涵蓋範圍比它想
# 代表的東西寬。它想代表的是「這次回測用的分母」，而分母只由 confirmed=true 的
# 項目與其 expected_findings 構成。但雜湊也吃進了兩類跟分母無關的內容：
#   1. confirmed 還沒填（false／null）的候選：這些不進分母，光是多抓到一筆新候選
#      就會讓 sha 變。
#   2. 這個函式產出的 fix_commits：build-benchmark.sh 的合併規則只保留舊檔的
#      confirmed 與 expected_findings，fix_commits 屬於「機器算出來的欄位」，
#      每次重建都用新值蓋回去，值一變 sha 就跟著變。
# 偏誤方向只有一邊：sha 會多報「分母不同」，不會漏報「分母其實換了」。所以拿兩份
# summary 對比時，sha 相同仍可信；sha 不同則不足以斷定分母變了，要自己再看一眼
# confirmed 的內容。
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
  # --paginate --slurp：GitHub 的 commits 端點回的是新到舊排序，只取第一頁的話
  # 截斷掉的是「最舊的那些」—— 也就是最接近 PR 合併時間的那批，而 fix commit
  # 通常就緊接在合併之後。這個截斷的方向剛好砍掉最該收的資料。
  #
  # --slurp 把每一頁的陣列包成陣列的陣列，所以下面要先 add 攤平。沒有 --slurp
  # 的話 gh 會把多頁輸出成多個獨立的 JSON 陣列（不是一個），jq 只會處理第一個。
  #
  # 上限用 until 那個時間窗控制（呼叫端給的），不另外設頁數上限：設了就是回到
  # 同一個問題，只是門檻高一點而已。
  gh api --paginate --slurp \
    "repos/$repo/commits?since=$merged&until=$until&per_page=100" 2>/dev/null \
    | jq --arg own "$own" --arg pr "$pr" '
      [ (add // []) | .[]
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

# PR 的檔案清單一定要分頁，理由與 backtest_fix_commits 相同：per_page 的上限
# 是 100，一個改到 180 個檔案的 PR 只會回前 100 筆。截斷的後果不是報錯，是
# 「這個 PR 沒有候選」——fix commit 若重疊在第 150 個檔案上，區間表裡根本沒有
# 那個檔案，比對必然落空，而 build-benchmark.sh 會印出一個乾淨的「候選 0 筆」
# 加結束碼 0，跟一個真的沒有後續修正的 PR 完全分不出來。
#
# --slurp 把每一頁的陣列包成陣列的陣列，所以要先 add 攤平。gh 與 jq 的退出碼
# 分兩步接：寫成單一管線的話，gh 失敗時 jq 對空輸入照樣回 0，失敗會被吞掉。
backtest_pr_ranges() {
  local repo="$1" pr="$2" raw files
  raw="$(gh api --paginate --slurp "repos/$repo/pulls/$pr/files?per_page=100" 2>/dev/null)" \
    || return 1
  files="$(printf '%s' "$raw" | jq 'add // []')" || return 1
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
# 這種候選會憑空消失，而漏掉的候選補不回來。
#
# `// []` 是 load-bearing，不是防禦性冗餘：fix commit 完全沒碰到 PR 改過的檔案時
# $b[$pa.key] 是 null，少了它 jq 會直接 "Cannot iterate over null" 中斷，
# 呼叫端 scripts/build-benchmark.sh 拿到的是空字串而不是 "[]"，一個真的沒有重疊
# 的 fix commit 會變成整趟掃描的例外。這種輸入必須安靜地回空清單。
#
# 這裡沒有逆序區間（起 > 迄）的守衛，因為輸入只可能來自 backtest_hunks_of，
# 它的輸出恆滿足 起 <= 迄（見 lib/backtest-hunks.sh）。改動那邊的產生規則時
# 要一起想這裡。
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
