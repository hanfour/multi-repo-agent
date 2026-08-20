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
    printf '%s' '[{"filename":"app/a.rb","patch":"@@ -92,7 +92,7 @@ def update\n x"},
                  {"filename":"app/b.rb","patch":"@@ -10,5 +10,5 @@ def x\n y"}]' ;;
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
    printf '%s' '[{"sha":"own999","commit":{"message":"fix(x): the PR itself"}},
                  {"sha":"aaa111","commit":{"message":"fix(y): overlapping fix"}},
                  {"sha":"bbb222","commit":{"message":"fix(z): unrelated file"}},
                  {"sha":"ccc333","commit":{"message":"feat(w): add new endpoint"}},
                  {"sha":"ddd444","commit":{"message":"fix(q): mentions the PR (#4919)"}},
                  {"sha":"fff666","commit":{"message":"Merge pull request #4873 from acme/misc-20260513-fix-seq"}},
                  {"sha":"jjj000","commit":{"message":"修正 function 不存在問題"}},
                  {"sha":"kkk111","commit":{"message":"修復 API 逾時問題"}},
                  {"sha":"lll222","commit":{"message":"雜項調整 20260316\nfix rubocop\nfix rspec"}},
                  {"sha":"mmm333","commit":{"message":"季度盤點作業\n本次一併修正相關欄位對應"}},
                  {"sha":"nnn444","commit":{"message":"[ODM] 上刊通報 修正轉檔"}}]' ;;
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

# bbb222 只動 app/c.rb,PR 沒碰過
c="$(backtest_commit_ranges acme/rails-app-1 bbb222)"
eq "不同檔案不重疊" "[]" "$(backtest_overlap "$a" "$c" | jq -c .)"

# eee555 改到 PR 也碰過的 app/b.rb,但行號 60-62 不落在 PR 的 10-14 內——
# 同檔案、不同行號,是唯一能分辨「照路徑比對」跟「照行號比對」的案例。
d="$(backtest_commit_ranges acme/rails-app-1 eee555)"
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
eq "相鄰不重疊" "[]" "$(backtest_overlap "$a" "$g" | jq -c .)"

echo "---"; echo "Passed: $pass"; echo "Failed: $errors"
exit $((errors > 0 ? 1 : 0))
