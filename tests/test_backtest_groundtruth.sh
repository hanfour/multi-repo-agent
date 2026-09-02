#!/usr/bin/env bash
# ground truth 候選判定 (lib/backtest-groundtruth.sh)。用 PATH shim 假造 gh。
set -uo pipefail
MRA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$MRA_DIR/lib/backtest-hunks.sh"

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin"
# GH_CALLS 記錄每次呼叫實際組出來的完整參數(含 query string)，讓測試能
# 檢查 backtest_merged_prs 真的送出 sort=created，不是繼續送 sort=updated
# (Ruling 27)。export 出去，stub 自己的行程才讀得到這個路徑。
export GH_CALLS="$TMP/gh-calls.log"
: > "$GH_CALLS"
cat > "$TMP/bin/gh" <<'SHIM'
#!/usr/bin/env bash
echo "$*" >> "$GH_CALLS"
case "$*" in
  *"pulls/4919/files"*)
    # 陣列的陣列：真實的 `gh api --paginate --slurp` 就是這個形狀，一頁一個
    # 元素。backtest_pr_ranges 現在要分頁（PR 可能改到超過 100 個檔案），
    # 所以 stub 也要回這個形狀，否則測的是一個不存在的回應。
    printf '%s' '[[{"filename":"app/a.rb","patch":"@@ -92,7 +92,7 @@ def update\n x"},
                   {"filename":"app/b.rb","patch":"@@ -10,5 +10,5 @@ def x\n y"}]]' ;;
  *"commits/aaa111"*)
    printf '%s' '{"files":[{"filename":"app/a.rb","patch":"@@ -95,2 +95,4 @@ def update\n z"}]}' ;;
  *"commits/bbb222"*)
    printf '%s' '{"files":[{"filename":"app/c.rb","patch":"@@ -1,2 +1,2 @@\n w"}]}' ;;
  *"commits/eee555"*)
    printf '%s' '{"files":[{"filename":"app/b.rb","patch":"@@ -60,3 +60,3 @@ def y\n z"}]}' ;;
  *"commits/ggg777"*)
    printf '%s' '{"files":[{"filename":"app/a.rb","patch":"@@ -98,7 +98,7 @@ def update\n p"}]}' ;;
  *"commits/hhh888"*)
    printf '%s' '{"files":[{"filename":"app/a.rb","patch":"@@ -85,8 +85,8 @@ def update\n q"}]}' ;;
  *"commits/iii999"*)
    printf '%s' '{"files":[{"filename":"app/a.rb","patch":"@@ -99,7 +99,7 @@ def update\n r"}]}' ;;
  *"commits?since"*|*"commits?"*)
    # 真實的 `gh api --paginate --slurp` 回的是「陣列的陣列」，一頁一個元素。
    # 這裡刻意分成兩頁：第二頁放 nnn444，模擬跨頁的情況。GitHub 的 commits
    # 端點是新到舊排序，所以第二頁裝的是比較舊的、也就是最接近 PR 合併時間
    # 的那批 —— fix commit 最可能出現的位置。沒有分頁的實作看不到第二頁。
    printf '%s' '[[{"sha":"own999","commit":{"message":"fix(x): the PR itself"}},
                   {"sha":"aaa111","commit":{"message":"fix(y): overlapping fix"}},
                   {"sha":"bbb222","commit":{"message":"fix(z): unrelated file"}},
                   {"sha":"ccc333","commit":{"message":"feat(w): add new endpoint"}},
                   {"sha":"ddd444","commit":{"message":"fix(q): mentions the PR (#4919)"}},
                   {"sha":"fff666","commit":{"message":"Merge pull request #4873 from acme/misc-20260513-fix-seq"}},
                   {"sha":"jjj000","commit":{"message":"修正 function 不存在問題"}},
                   {"sha":"kkk111","commit":{"message":"修復 API 逾時問題"}},
                   {"sha":"lll222","commit":{"message":"雜項調整 20260316\nfix rubocop\nfix rspec"}},
                   {"sha":"mmm333","commit":{"message":"季度盤點作業\n本次一併修正相關欄位對應"}}],
                  [{"sha":"nnn444","commit":{"message":"[ODM] 上刊通報 修正轉檔"}}]]' ;;
  *"pulls?state=closed"*"&page=1"*)
    # since 模式逐頁抓：第一頁滿 100 筆，created_at 從 2026-08-15 起一天一筆
    # 往回排到 2026-05-08（跟真實端點一樣新到舊）。since 落在這 100 天內的
    # 話，第一頁就該停；since 更早才需要翻第二頁。
    jq -nc '[range(100) | {number: (5100 - .),
                           created_at: (("2026-08-15T00:00:00Z" | fromdate) - . * 86400 | todate),
                           merged_at: "2026-08-16T00:00:00Z",
                           merge_commit_sha: ("p1-" + tostring)}]' ;;
  *"pulls?state=closed"*"&page=2"*)
    # 第二頁不滿 100 筆：抓完這頁就該停，不能再要第三頁。
    if [[ "${MRA_TEST_PAGE2_FAIL:-0}" == "1" ]]; then exit 1; fi
    printf '%s' '[{"number":4920,"created_at":"2026-04-10T00:00:00Z","merged_at":"2026-04-11T00:00:00Z","merge_commit_sha":"www999"},
                  {"number":4919,"created_at":"2026-03-05T00:00:00Z","merged_at":"2026-03-10T09:09:52Z","merge_commit_sha":"own999"},
                  {"number":4917,"created_at":"2026-02-01T00:00:00Z","merged_at":"2026-02-02T00:00:00Z","merge_commit_sha":"old111"}]' ;;
  *"pulls?state=closed"*"&page="*)
    echo "UNEXPECTED_PAGE $*" >&2; exit 1 ;;
  *"pulls?state=closed"*)
    printf '%s' '[{"number":4920,"created_at":"2026-08-15T00:00:00Z","merged_at":"2026-08-16T00:00:00Z","merge_commit_sha":"www999"},
                  {"number":4919,"created_at":"2026-08-05T00:00:00Z","merged_at":"2026-08-10T09:09:52Z","merge_commit_sha":"own999"},
                  {"number":4918,"created_at":"2026-08-01T00:00:00Z","merged_at":null,"merge_commit_sha":null}]' ;;
esac
exit 0
SHIM
chmod +x "$TMP/bin/gh"; export PATH="$TMP/bin:$PATH"

source "$MRA_DIR/lib/backtest-groundtruth.sh"

errors=0; pass=0
ok()   { echo "PASS: $1"; pass=$((pass+1)); }
fail() { echo "FAIL: $1"; errors=$((errors+1)); }
eq()   { if [[ "$2" == "$3" ]]; then ok "$1"; else fail "$1 — expected [$2] got [$3]"; fi; }
has()  { case "$2" in *"$3"*) ok "$1" ;; *) fail "$1 — 沒看到「$3」：$2" ;; esac; }
lacks(){ case "$2" in *"$3"*) fail "$1 — 不該看到「$3」：$2" ;; *) ok "$1" ;; esac; }

# 未定義的指令會讓 bash 印 command not found 然後繼續，那個斷言既不算 pass
# 也不算 fail，測試照樣印 Failed: 0。這道讓它直接算成失敗。
command_not_found_handle() {
  fail "呼叫了未定義的指令 $1（斷言被靜默跳過）"
  return 127
}

eq "只取 merged(4918 沒有 merged_at 被排除)" "[4920,4919]" \
  "$(backtest_merged_prs acme/rails-app-1 10 | jq -c '[.[].n]')"

# --- Ruling 27：sort=created，不是 sort=updated -----------------------------
: > "$GH_CALLS"
backtest_merged_prs acme/rails-app-1 10 >/dev/null
gh_call="$(grep 'pulls?state=closed' "$GH_CALLS")"
has_sort_created() { case "$1" in *"sort=created"*) return 0 ;; *) return 1 ;; esac; }
if has_sort_created "$gh_call"; then
  ok "backtest_merged_prs 組出來的 URL 帶 sort=created"
else
  fail "backtest_merged_prs 組出來的 URL 沒有 sort=created：$gh_call"
fi
case "$gh_call" in
  *"sort=updated"*) fail "backtest_merged_prs 不該再送 sort=updated：$gh_call" ;;
  *) ok "backtest_merged_prs 沒有送 sort=updated" ;;
esac

# --- 可選的日期範圍參數(until)：只收 created_at 早於這個時間點的 PR，
#     嚴格小於。4920 建立於 08-15，用 08-10 當 until 應該被排除，只剩
#     4919(建立於 08-05)------------------------------------------------
eq "給 until=2026-08-10 時，4920(建立於 08-15)被排除" "[4919]" \
  "$(backtest_merged_prs acme/rails-app-1 10 2026-08-10T00:00:00Z | jq -c '[.[].n]')"

# 邊界：until 剛好等於某筆 PR 自己的 created_at，嚴格小於，該筆自己也要被
# 排除(不是 <=)。4919 的 created_at 剛好是 2026-08-05T00:00:00Z。
eq "until 剛好等於 4919 的 created_at 時，4919 自己也被排除(嚴格小於)" "[]" \
  "$(backtest_merged_prs acme/rails-app-1 10 2026-08-05T00:00:00Z | jq -c '[.[].n]')"

# 沒給 until 時(省略第三個參數)，行為與現在完全一致：不做這層過濾。
eq "沒給 until 時行為與現在一致(等同不過濾)" "[4920,4919]" \
  "$(backtest_merged_prs acme/rails-app-1 10 | jq -c '[.[].n]')"
eq "14 天視窗" "2026-08-24T09:09:52Z" "$(backtest_window_end 2026-08-10T09:09:52Z 14)"
eq "7 天視窗"  "2026-08-17T09:09:52Z" "$(backtest_window_end 2026-08-10T09:09:52Z 7)"

# 排除自己的 merge commit(own999)、帶 #4919 的 commit(own999、ddd444)、
# Merge commit(fff666)、非 fix 的 commit(ccc333)、以及標題沒有 fix 意涵、
# fix 字樣只出現在 squash body 裡的 commit(lll222、mmm333)
eq "候選 fix commit" '["aaa111","bbb222","jjj000","kkk111","nnn444"]' \
  "$(backtest_fix_commits acme/rails-app-1 4919 2026-08-10T09:09:52Z own999 14 | jq -c '[.[].sha]')"

# 標題只有中文、完全沒出現任何英文 fix 字樣,也要收(修正)
eq "中文 修正 被收入" "true" \
  "$(backtest_fix_commits acme/rails-app-1 4919 2026-08-10T09:09:52Z own999 14 | jq 'any(.[]; .sha == "jjj000")')"

# 標題只有中文、完全沒出現任何英文 fix 字樣,也要收(修復)
eq "中文 修復 被收入" "true" \
  "$(backtest_fix_commits acme/rails-app-1 4919 2026-08-10T09:09:52Z own999 14 | jq 'any(.[]; .sha == "kkk111")')"

# 英文 fix(scope): 仍然要收,既有行為沒有被新規則弄壞
eq "英文 fix(scope) 仍收入" "true" \
  "$(backtest_fix_commits acme/rails-app-1 4919 2026-08-10T09:09:52Z own999 14 | jq 'any(.[]; .sha == "aaa111")')"

# 標題沒有 fix 意涵,squash 進 body 的英文 fix 字樣不該讓它被收
eq "body 帶英文 fix 不收" "false" \
  "$(backtest_fix_commits acme/rails-app-1 4919 2026-08-10T09:09:52Z own999 14 | jq 'any(.[]; .sha == "lll222")')"

# 標題沒有 fix 意涵,squash 進 body 的中文修正字樣不該讓它被收
eq "body 帶中文修正不收" "false" \
  "$(backtest_fix_commits acme/rails-app-1 4919 2026-08-10T09:09:52Z own999 14 | jq 'any(.[]; .sha == "mmm333")')"

# fix 詞彙出現在標題句子中間、不是開頭——這個團隊的標題不是 conventional
# commit 格式,錨定在開頭會漏掉這種真候選。
eq "修正 出現在句中仍收" "true" \
  "$(backtest_fix_commits acme/rails-app-1 4919 2026-08-10T09:09:52Z own999 14 | jq 'any(.[]; .sha == "nnn444")')"

# 隔離測試:own999 的 message 沒有帶 #4919,#pr 排除攔不到它,只有靠 sha 排除。
# 拿掉「排除自己的 merge commit」這個條件時,只有這筆會現身。
eq "own sha 被排除" "false" \
  "$(backtest_fix_commits acme/rails-app-1 4919 2026-08-10T09:09:52Z own999 14 | jq 'any(.[]; .sha == "own999")')"

# 隔離測試:ddd444 的 sha 不是 own999,sha 排除攔不到它,只有靠 #pr 排除。
# 拿掉「排除帶 #<pr> 的 commit」這個條件時,只有這筆會現身。
eq "#pr 引用被排除" "false" \
  "$(backtest_fix_commits acme/rails-app-1 4919 2026-08-10T09:09:52Z own999 14 | jq 'any(.[]; .sha == "ddd444")')"

# fff666 是 Merge commit,分支名裡帶 "fix" 字樣會被子字串比對誤收,
# 要靠 `^Merge ` 排除才會被擋下。
eq "merge commit 被排除" "false" \
  "$(backtest_fix_commits acme/rails-app-1 4919 2026-08-10T09:09:52Z own999 14 | jq 'any(.[]; .sha == "fff666")')"

eq "PR 的區間" '{"app/a.rb":[[92,98]],"app/b.rb":[[10,14]]}' \
  "$(backtest_pr_ranges acme/rails-app-1 4919 | jq -cS .)"
eq "commit 的區間" '{"app/a.rb":[[95,98]]}' \
  "$(backtest_commit_ranges acme/rails-app-1 aaa111 | jq -cS .)"

# aaa111 改到 app/a.rb 的 95-98,與 PR 的 92-98 重疊
a="$(backtest_pr_ranges acme/rails-app-1 4919)"
b="$(backtest_commit_ranges acme/rails-app-1 aaa111)"
eq "重疊一筆"   "1"          "$(backtest_overlap "$a" "$b" | jq 'length')"
eq "重疊在 a.rb" '"app/a.rb"' "$(backtest_overlap "$a" "$b" | jq -c '.[0].path')"

# 下面三筆「不重疊」的斷言都各配一筆前置斷言，先釘住那個 commit 真的有區間
# 可以比。原因：backtest_overlap 對「兩邊沒有交集」跟「有一邊根本是空的」都回
# `[]`,少了前置斷言的話,backtest_commit_ranges 壞掉回 `{}` 時這三筆照樣綠,
# 量出來的「沒有重疊」其實是「沒有資料」。

# bbb222 只動 app/c.rb,PR 沒碰過
c="$(backtest_commit_ranges acme/rails-app-1 bbb222)"
eq "前置:bbb222 查得到區間" '{"app/c.rb":[[1,2]]}' "$(printf '%s' "$c" | jq -cS .)"
eq "不同檔案不重疊" "[]" "$(backtest_overlap "$a" "$c" | jq -c .)"

# eee555 改到 PR 也碰過的 app/b.rb,但行號 60-62 不落在 PR 的 10-14 內——
# 同檔案、不同行號,是唯一能分辨「照路徑比對」跟「照行號比對」的案例。
d="$(backtest_commit_ranges acme/rails-app-1 eee555)"
eq "前置:eee555 查得到區間" '{"app/b.rb":[[60,62]]}' "$(printf '%s' "$d" | jq -cS .)"
eq "同檔不同行不重疊" "[]" "$(backtest_overlap "$a" "$d" | jq -c .)"

# 邊界相接(inclusive)測試。PR 的 app/a.rb 區間是 92-98。
# ggg777 的起點(98)剛好等於 PR 的終點——fix commit 接著 PR 新增的最後一行
# 往下寫,是常見的真實形狀,必須算重疊,不能因為邊界改成 exclusive 就憑空消失。
e="$(backtest_commit_ranges acme/rails-app-1 ggg777)"
eq "邊界相接(fix 起點=PR 終點)算重疊" "1" "$(backtest_overlap "$a" "$e" | jq 'length')"

# hhh888 的終點(92)剛好等於 PR 的起點——另一個方向的邊界相接,同樣必須算重疊。
# 跟上面那筆各自對應 jq 比對式裡不同的那一半（$rb[0] <= $ra[1] / $ra[0] <= $rb[1]）,
# 任一半被改成 exclusive 都只會弄壞其中一筆,不會互相遮蔽。
f="$(backtest_commit_ranges acme/rails-app-1 hhh888)"
eq "邊界相接(fix 終點=PR 起點)算重疊" "1" "$(backtest_overlap "$a" "$f" | jq 'length')"

# iii999 的起點(99)在 PR 終點(98)之後,是真正不相鄰、沒有交集,必須不算重疊——
# 用來確保上面兩筆邊界相接測試不是靠「全部都算重疊」矇混過關。
g="$(backtest_commit_ranges acme/rails-app-1 iii999)"
eq "前置:iii999 查得到區間" '{"app/a.rb":[[99,105]]}' "$(printf '%s' "$g" | jq -cS .)"
eq "相鄰不重疊" "[]" "$(backtest_overlap "$a" "$g" | jq -c .)"

# --- 空區間集：backtest_overlap 的 `// []` 守衛 -------------------------------
# 這是行為斷言,不是源碼文字比對。fix commit 的 patch 全是純刪除時,
# backtest_commit_ranges 會誠實地回一個空物件,而 scripts/build-benchmark.sh
# 會照樣把它餵給 backtest_overlap。少了 `// []`,$b[$pa.key] 拿到的 null 會讓
# jq 以 "Cannot iterate over null" 中斷:退出碼非 0、標準輸出是空字串,
# 呼叫端接著跑的 `jq 'length'` 又吃到空字串再失敗一次。
# 分成「輸出是 []」與「退出碼是 0」兩筆:只驗輸出的話,jq 中斷時輸出的空字串
# 跟 `[]` 差得夠遠會轉紅,但錯誤訊息指不出是中斷還是算錯。
empty_ov="$(backtest_overlap '{"app/a.rb":[[92,98]]}' '{}')"; empty_rc=$?
eq "b 側為空區間集時回空清單" "[]" "$empty_ov"
eq "b 側為空區間集時不中斷" "0" "$empty_rc"

# a 側為空的方向由 jq 的 to_entries 天然處理,一併釘住,免得日後有人把外層
# 換成需要 a 非空的寫法。
empty_a_ov="$(backtest_overlap '{}' '{"app/a.rb":[[92,98]]}')"; empty_a_rc=$?
eq "a 側為空區間集時回空清單" "[]" "$empty_a_ov"
eq "a 側為空區間集時不中斷" "0" "$empty_a_rc"

# --- 同一個檔案有多個區間 -----------------------------------------------------
# PR 在一個檔案裡改好幾段是常態。只比第一段的話,落在後面幾段的真候選會漏掉,
# 而漏掉的候選補不回來。
eq "同檔多區間任一重疊即命中" "1" \
  "$(backtest_overlap '{"app/a.rb":[[1,5],[100,110]]}' '{"app/a.rb":[[105,120]]}' | jq 'length')"
eq "命中的是重疊的那一段,不是第一段" "[100,110]" \
  "$(backtest_overlap '{"app/a.rb":[[1,5],[100,110]]}' '{"app/a.rb":[[105,120]]}' | jq -c '.[0].pr_range')"
eq "同檔多區間全不重疊為空" "[]" \
  "$(backtest_overlap '{"app/a.rb":[[1,5]]}' '{"app/a.rb":[[10,20],[30,40]]}' | jq -c .)"

# commits 端點一定要分頁。GitHub 回的是新到舊排序，只取第一頁會截斷掉最舊的
# 那批 —— 也就是最接近 PR 合併時間、fix commit 最可能出現的位置。上面的 stub
# 刻意把 nnn444 放在第二頁，所以「候選 fix commit」那條斷言已經在驗跨頁；
# 這裡再直接釘住旗標本身，讓有人拿掉 --paginate 時錯誤訊息指得更清楚。
has "commits 查詢有帶 --paginate" "$(cat "$GH_CALLS")" "--paginate"
has "commits 查詢有帶 --slurp" "$(cat "$GH_CALLS")" "--slurp"

# PR 的檔案清單同樣要分頁：per_page 上限是 100，改到 180 個檔案的 PR 只會回
# 前 100 筆，而截斷的後果不是報錯，是「這個 PR 沒有候選」——fix commit 若重疊
# 在第 150 個檔案上，區間表裡根本沒有那個檔案，比對必然落空。
: > "$GH_CALLS"
backtest_pr_ranges acme/rails-app-1 4919 >/dev/null
pr_files_call="$(grep 'pulls/4919/files' "$GH_CALLS")"
has "PR 檔案查詢有帶 --paginate" "$pr_files_call" "--paginate"
has "PR 檔案查詢有帶 --slurp" "$pr_files_call" "--slurp"

# $limit 直接進 per_page，而 GitHub 的上限是 100：給 300 的話 API 靜默回 100
# 筆，呼叫端以為分母是 300、實際是 100，沒有任何訊號。這裡要的是明確失敗，
# 不是一個比要求少的分母。
limit_err="$(backtest_merged_prs acme/rails-app-1 300 2>&1)"; limit_rc=$?
if [[ "$limit_rc" -ne 0 ]]; then
  ok "limit 超過 100 時退出非 0"
else
  fail "limit 超過 100 必須擋下來，不能靜默給一個比要求少的分母"
fi
has "印出 LIMIT_TOO_LARGE" "$limit_err" "LIMIT_TOO_LARGE"

limit_bad="$(backtest_merged_prs acme/rails-app-1 abc 2>&1)"; limit_bad_rc=$?
if [[ "$limit_bad_rc" -ne 0 ]]; then
  ok "limit 非數字時退出非 0"
else
  fail "limit 非數字必須擋下來"
fi
has "印出 LIMIT_INVALID" "$limit_bad" "LIMIT_INVALID"

# 邊界：100 本身要放行，不然這道守衛會連正常用法都擋掉。
backtest_merged_prs acme/rails-app-1 100 >/dev/null 2>&1
eq "limit 剛好 100 時放行" "0" "$?"

# --- since：抓「這個時間點之後建立的全部 merged PR」，要逐頁翻 -------------
# 沒有 since 的路徑只抓最近 N 筆一頁，永遠碰不到第 101 筆以後的 PR；掃一年
# 的 PR 要靠 since。stub 第一頁 100 筆（08-15 到 05-08）、第二頁 3 筆。
: > "$GH_CALLS"
since_out="$(backtest_merged_prs acme/rails-app-1 100 "" 2026-03-05T00:00:00Z)"; since_rc=$?
eq "since 模式退出 0" "0" "$since_rc"
eq "since=03-05 翻到第二頁：第一頁 100 筆 + 第二頁 created_at >= since 的 2 筆" "102" \
  "$(printf '%s' "$since_out" | jq 'length')"
eq "since 剛好等於 4919 的 created_at 時 4919 要收（>=，跟 until 的嚴格小於相對）" "true" \
  "$(printf '%s' "$since_out" | jq 'any(.[]; .n == 4919)')"
eq "早於 since 的 4917 不收" "false" "$(printf '%s' "$since_out" | jq 'any(.[]; .n == 4917)')"
eq "第二頁不滿 100 筆就停，沒有去要第三頁" "0" "$(grep -c '&page=3' "$GH_CALLS")"
eq "since 模式仍然 sort=created" "2" "$(grep 'pulls?state=closed' "$GH_CALLS" | grep -c 'sort=created')"

# since 落在第一頁範圍內：第一頁最後一筆（05-08）已經早於 since，不該再翻頁
: > "$GH_CALLS"
since_out="$(backtest_merged_prs acme/rails-app-1 100 "" 2026-06-01T00:00:00Z)"
eq "since=06-01 只收第一頁裡 06-01 到 08-15 的 76 筆" "76" "$(printf '%s' "$since_out" | jq 'length')"
eq "第一頁最後一筆已早於 since 就停，沒有去要第二頁" "0" "$(grep -c '&page=2' "$GH_CALLS")"

# since 與 until 一起給：兩端都要生效
since_out="$(backtest_merged_prs acme/rails-app-1 100 2026-08-01T00:00:00Z 2026-06-01T00:00:00Z)"
eq "since=06-01 且 until=08-01：只剩 06-01 到 07-31 的 61 筆" "61" "$(printf '%s' "$since_out" | jq 'length')"

# 沒給 since：不分頁，URL 不帶 page=，行為跟現在完全一樣
: > "$GH_CALLS"
backtest_merged_prs acme/rails-app-1 10 >/dev/null
eq "沒給 since 時 URL 不帶 &page=" "0" "$(grep -c '&page=' "$GH_CALLS")"

# since 模式某一頁抓不到：要回非 0，不能把抓到一半的清單當完整結果
MRA_TEST_PAGE2_FAIL=1 backtest_merged_prs acme/rails-app-1 100 "" 2026-03-05T00:00:00Z >/dev/null 2>&1
eq "since 模式翻頁失敗回非 0" "1" "$?"

# backtest_overlap 對畸形輸入要回非 0。scripts/build-benchmark.sh 現在會接住
# 它的退出碼（舊版丟掉，jq 失敗時 $ov 是空字串，而 bash 的算術比較把空字串
# 當 0，一筆真正的候選就這樣被當成「沒有重疊」悄悄消失）。它若對畸形輸入
# 照樣回 0，那個守衛就是死碼。
backtest_overlap '{}' 'not json' >/dev/null 2>&1
if [[ "$?" -ne 0 ]]; then
  ok "backtest_overlap 對畸形輸入退出非 0（呼叫端的守衛才有意義）"
else
  fail "backtest_overlap 對畸形輸入回 0，呼叫端接退出碼等於白接"
fi

echo "---"; echo "Passed: $pass"; echo "Failed: $errors"
exit $((errors > 0 ? 1 : 0))
