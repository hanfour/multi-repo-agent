#!/usr/bin/env bash
# ground truth 候選判定 (lib/backtest-groundtruth.sh)。用 PATH shim 假造 gh。
set -uo pipefail
MRA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$MRA_DIR/lib/backtest-hunks.sh"

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin"
cat > "$TMP/bin/gh" <<'SHIM'
#!/usr/bin/env bash
case "$*" in
  *"pulls/4919/files"*)
    printf '%s' '[{"filename":"app/a.rb","patch":"@@ -92,7 +92,7 @@ def update\n x"},
                  {"filename":"app/b.rb","patch":"@@ -10,5 +10,5 @@ def x\n y"}]' ;;
  *"commits/aaa111"*)
    printf '%s' '{"files":[{"filename":"app/a.rb","patch":"@@ -95,2 +95,4 @@ def update\n z"}]}' ;;
  *"commits/bbb222"*)
    printf '%s' '{"files":[{"filename":"app/c.rb","patch":"@@ -1,2 +1,2 @@\n w"}]}' ;;
  *"commits?since"*|*"commits?"*)
    printf '%s' '[{"sha":"own999","commit":{"message":"fix(x): the PR itself (#4919)"}},
                  {"sha":"aaa111","commit":{"message":"fix(y): overlapping fix"}},
                  {"sha":"bbb222","commit":{"message":"fix(z): unrelated file"}},
                  {"sha":"ccc333","commit":{"message":"feat(w): not a fix"}}]' ;;
  *"pulls?state=closed"*)
    printf '%s' '[{"number":4919,"merged_at":"2026-08-10T09:09:52Z","merge_commit_sha":"own999"},
                  {"number":4918,"merged_at":null,"merge_commit_sha":null}]' ;;
esac
exit 0
SHIM
chmod +x "$TMP/bin/gh"; export PATH="$TMP/bin:$PATH"

source "$MRA_DIR/lib/backtest-groundtruth.sh"

errors=0; pass=0
ok()   { echo "PASS: $1"; pass=$((pass+1)); }
fail() { echo "FAIL: $1"; errors=$((errors+1)); }
eq()   { if [[ "$2" == "$3" ]]; then ok "$1"; else fail "$1 — expected [$2] got [$3]"; fi; }

eq "只取 merged" "[4919]" "$(backtest_merged_prs acme/rails-app-1 10 | jq -c '[.[].n]')"
eq "14 天視窗" "2026-08-24T09:09:52Z" "$(backtest_window_end 2026-08-10T09:09:52Z 14)"
eq "7 天視窗"  "2026-08-17T09:09:52Z" "$(backtest_window_end 2026-08-10T09:09:52Z 7)"

# 排除自己的 merge commit(own999)、帶 #4919 的 commit、以及非 fix 的 commit
eq "候選 fix commit" '["aaa111","bbb222"]' \
  "$(backtest_fix_commits acme/rails-app-1 4919 2026-08-10T09:09:52Z own999 14 | jq -c '[.[].sha]')"

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

echo "---"; echo "Passed: $pass"; echo "Failed: $errors"
exit $((errors > 0 ? 1 : 0))
