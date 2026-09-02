#!/usr/bin/env bash
# blame 歸因 (lib/backtest-blame.sh)：fix commit 改到的舊行是不是受審 PR 寫的。
#
# 用一個真的暫存 git repo 造出兩種合併方式的 PR，再造 fix commit，不用 stub：
# blame 的結果就是要靠真 git 算出來，假造的話測的是假造本身。
#
#   init      a.rb 十行、b.rb 六行
#   PR #7     squash 合併：一個 commit 改 a.rb 第 3～5 行，標題結尾 (#7)
#   PR #8     merge 合併：分支上第一個 commit 改 b.rb 第 2 行、第二個在最上面
#             插一行，--no-ff 合進來
#   chore     在 a.rb 最上面插兩行，讓後面 fix 看到的行號跟 PR 當時的行號錯開
#   fix F1    改 a.rb 的「seven4」（PR #7 寫的）、在「seven5」後插一行、
#             改「l9」（init 寫的）
#   fix F2    改 b.rb 的「eight2」（PR #8 分支上第一個 commit 寫的）
#   fix F3    新增檔案 c.rb（舊檔側不存在，沒有任何舊行可歸因）
set -uo pipefail
MRA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$MRA_DIR/lib/backtest-blame.sh"

errors=0; pass=0
ok()   { echo "PASS: $1"; pass=$((pass+1)); }
fail() { echo "FAIL: $1"; errors=$((errors+1)); }
eq()   { if [[ "$2" == "$3" ]]; then ok "$1"; else fail "$1 — expected [$2] got [$3]"; fi; }

command_not_found_handle() {
  fail "呼叫了未定義的指令 $1（斷言被靜默跳過）"
  return 127
}

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
R="$TMP/repo"
mkdir -p "$R"
g() { git -C "$R" -c user.name=t -c user.email=t@example.com -c commit.gpgsign=false "$@"; }
g init -q -b main >/dev/null 2>&1 || g init -q >/dev/null
g checkout -q -b main 2>/dev/null || true

printf 'l%d\n' 1 2 3 4 5 6 7 8 9 10 > "$R/a.rb"
printf 'b%d\n' 1 2 3 4 5 6 > "$R/b.rb"
g add -A; g commit -q -m "init"
INIT="$(g rev-parse HEAD)"

# PR #7：squash 合併（單親 commit，標題結尾 (#7)）
sed -i.bak -e 's/^l3$/seven3/' -e 's/^l4$/seven4/' -e 's/^l5$/seven5/' "$R/a.rb"; rm -f "$R/a.rb.bak"
g commit -q -am "feat: seven (#7)"
MC7="$(g rev-parse HEAD)"

# PR #8：merge 合併（雙親 merge commit）
g checkout -q -b feat8
sed -i.bak 's/^b2$/eight2/' "$R/b.rb"; rm -f "$R/b.rb.bak"
g commit -q -am "eight step 1"
E1="$(g rev-parse HEAD)"
# 第二個 commit 在最上面插一行：分支 head 裡 eight2 是第 3 行，但 blame 指到
# 的是第一個 commit（那時它是第 2 行），行號要用內容對回分支 head 才對
{ printf 'btop\n'; cat "$R/b.rb"; } > "$R/b.rb.new" && mv "$R/b.rb.new" "$R/b.rb"
g commit -q -am "eight step 2"
E2="$(g rev-parse HEAD)"
g checkout -q main
g merge -q --no-ff -m "Merge pull request #8 from acme/feat8" feat8
MC8="$(g rev-parse HEAD)"

# 合併後別人的改動：a.rb 最上面插兩行，seven4 從第 4 行變第 6 行
{ printf 'top1\ntop2\n'; cat "$R/a.rb"; } > "$R/a.rb.new" && mv "$R/a.rb.new" "$R/a.rb"
g commit -q -am "chore: prepend"

# fix F1
sed -i.bak -e 's/^seven4$/fixed4/' -e 's/^seven5$/seven5\ninserted/' -e 's/^l9$/fixed9/' "$R/a.rb"; rm -f "$R/a.rb.bak"
g commit -q -am "fix: a"
F1="$(g rev-parse HEAD)"

# fix F2
sed -i.bak 's/^eight2$/fixed2/' "$R/b.rb"; rm -f "$R/b.rb.bak"
g commit -q -am "fix: b"
F2="$(g rev-parse HEAD)"

# fix F3：新增檔案
printf 'c1\nc2\n' > "$R/c.rb"
g add -A; g commit -q -m "fix: add c"
F3="$(g rev-parse HEAD)"

# --- backtest_pr_commit_set ---------------------------------------------------
eq "squash PR 的 commit 集合就是 merge commit 自己" "$MC7" \
  "$(backtest_pr_commit_set "$R" "$MC7")"
set8="$(backtest_pr_commit_set "$R" "$MC8")"
eq "merge PR 的 commit 集合含分支上第一個 commit" "1" "$(printf '%s\n' "$set8" | grep -c "$E1")"
eq "merge PR 的 commit 集合含分支上第二個 commit" "1" "$(printf '%s\n' "$set8" | grep -c "$E2")"
eq "merge PR 的 commit 集合不含 init" "0" "$(printf '%s\n' "$set8" | grep -c "$INIT")"
eq "merge PR 的 commit 集合不含 squash PR #7" "0" "$(printf '%s\n' "$set8" | grep -c "$MC7")"
backtest_pr_commit_set "$R" 0000000000000000000000000000000000000000 >/dev/null 2>&1
eq "查不到的 commit 回非 0" "1" "$?"

# --- backtest_pr_version_ref：PR 當時的版本（人工填 line 用的座標）------------
eq "squash PR 的版本就是 merge commit" "$MC7" \
  "$(g rev-parse "$(backtest_pr_version_ref "$R" "$MC7")")"
eq "merge PR 的版本是第二個父（分支 head）" "$E2" \
  "$(g rev-parse "$(backtest_pr_version_ref "$R" "$MC8")")"

# --- backtest_fix_hunks：fix commit 的 hunk，舊檔側／新檔側區間 ------------------
eq "F1 三個 hunk（改、純新增、改）" "mod	6	6	6	6
add	7	8	8	8
mod	11	11	12	12" "$(backtest_fix_hunks "$R" "$F1" a.rb)"
eq "新增檔案沒有舊行可歸因，不產生 hunk" "" "$(backtest_fix_hunks "$R" "$F3" c.rb)"

# --- backtest_blame_hunks：每個 hunk 的歸因比例與 PR 當時的行號 ----------------
h1="$(backtest_blame_hunks "$R" "$MC7" "$F1" a.rb)"
eq "blame_hunks 回合法 JSON 陣列、三個 hunk" "3" "$(printf '%s' "$h1" | jq 'length')"
eq "seven4 那個 hunk 全部歸到 PR #7" "1" "$(printf '%s' "$h1" | jq '.[0].ratio')"
eq "seven4 在 PR #7 當時是第 4 行（不是 fix 看到的第 6 行）" "[4]" \
  "$(printf '%s' "$h1" | jq -c '.[0].head_lines')"
eq "純新增 hunk 用上下兩行當錨點：seven5 歸 PR、l6 不歸" "0.5" \
  "$(printf '%s' "$h1" | jq '.[1].ratio')"
eq "純新增 hunk 的錨點行數是 2" "2" "$(printf '%s' "$h1" | jq '.[1].n')"
eq "l9 那個 hunk 沒有任何行歸到 PR #7" "0" "$(printf '%s' "$h1" | jq '.[2].ratio')"
eq "沒歸到 PR 的 hunk 沒有 head_lines" "[]" "$(printf '%s' "$h1" | jq -c '.[2].head_lines')"
eq "hunk 帶檔名與新檔側區間" '["a.rb",6,6]' \
  "$(printf '%s' "$h1" | jq -c '.[0] | [.path, .new_from, .new_to]')"
eq "hunk 帶 kind" '["mod","add","mod"]' "$(printf '%s' "$h1" | jq -c 'map(.kind)')"

# merge 合併的 PR：blame 指到分支上的 commit，行號要對回分支 head 的版本
h2="$(backtest_blame_hunks "$R" "$MC8" "$F2" b.rb)"
eq "eight2 歸到 PR #8（分支上的 commit 也算）" "1" "$(printf '%s' "$h2" | jq '.[0].ratio')"
eq "eight2 在分支 head 是第 3 行（不是它被寫下時的第 2 行）" "[3]" \
  "$(printf '%s' "$h2" | jq -c '.[0].head_lines')"

# 同一個 fix 對「不是它修的 PR」歸因要是 0：F2 改的是 b.rb，跟 PR #7 無關
h3="$(backtest_blame_hunks "$R" "$MC7" "$F2" b.rb)"
eq "F2 對 PR #7 的歸因是 0" "0" "$(printf '%s' "$h3" | jq '.[0].ratio')"

# 新增檔案：舊檔側不存在，回空陣列而不是失敗
eq "新增檔案回空陣列" "[]" "$(backtest_blame_hunks "$R" "$MC7" "$F3" c.rb | jq -c '.')"

# fix commit 不在本機：要回非 0，不能當成「沒有 hunk」
backtest_blame_hunks "$R" "$MC7" 0000000000000000000000000000000000000000 a.rb >/dev/null 2>&1
eq "fix commit 不在本機回非 0" "1" "$?"

# --- backtest_gap_days：fix 距合併的天數 -------------------------------------
eq "gap 天數（一位小數）" "5.5" "$(backtest_gap_days 2026-08-10T00:00:00Z 2026-08-15T12:00:00+00:00)"
eq "gap 天數（帶時區）" "1.0" "$(backtest_gap_days 2026-08-10T00:00:00Z 2026-08-11T08:00:00+08:00)"
backtest_gap_days not-a-date 2026-08-11T08:00:00+08:00 >/dev/null 2>&1
eq "日期壞掉回非 0" "1" "$?"

echo "---"; echo "Passed: $pass"; echo "Failed: $errors"
exit $((errors > 0 ? 1 : 0))
