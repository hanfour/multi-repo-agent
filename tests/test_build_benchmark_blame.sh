#!/usr/bin/env bash
# 基準集候選建構的 blame 歸因模式 (scripts/build-benchmark.sh --attribution blame)。
#
# PR 列表與 fix commit 列表照舊走 gh（PATH shim），hunk 與歸因走本機 clone
# （MRA_BACKTEST_WORKSPACE/<repo 第二段>）。本機 repo 是真的 git repo，shim
# 回傳的 sha 是它裡面真實的 commit。
#
#   init      a.rb 十行
#   PR #7     squash 合併，改第 3～5 行（seven3/seven4/seven5），合併於 08-10
#   fix F1    改 seven4：整個 hunk 歸到 PR #7（ratio 1.0），合併後 2 天
#   fix F2    改 seven5 與 l6（相鄰，同一個 hunk）：ratio 0.5
#   fix F3    改 l9：ratio 0，不該成為候選
#   fix F4    改 seven3，只在 origin 上、本機 clone 沒有：產生器要自己 fetch
#
# 本機 clone 是從 $TMP/remote clone 出來的，F4 在 clone 之後才推上 remote，
# 模擬「PR 合進已刪除的分支，merge commit 從任何 ref 都到不了，只能用 sha
# 直接 fetch」這種真實情況（super-dsp-2.0 30 個 PR 裡有 7 個）。
set -uo pipefail
MRA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export MRA_BENCHMARK_DIR="$TMP/bench"
export MRA_BACKTEST_WORKSPACE="$TMP/ws"
export MRA_TEST_SHAS="$TMP/shas"
mkdir -p "$TMP/bin" "$MRA_TEST_SHAS" "$MRA_BACKTEST_WORKSPACE"

R="$TMP/remote"
mkdir -p "$R"
g() { git -C "$R" -c user.name=t -c user.email=t@example.com -c commit.gpgsign=false "$@"; }
g init -q -b main >/dev/null 2>&1 || g init -q >/dev/null
g checkout -q -b main 2>/dev/null || true
printf 'l%d\n' 1 2 3 4 5 6 7 8 9 10 > "$R/a.rb"
g add -A; GIT_COMMITTER_DATE=2026-08-01T00:00:00Z g commit -q -m "init"
sed -i.bak -e 's/^l3$/seven3/' -e 's/^l4$/seven4/' -e 's/^l5$/seven5/' "$R/a.rb"; rm -f "$R/a.rb.bak"
GIT_COMMITTER_DATE=2026-08-10T00:00:00Z g commit -q -am "feat: seven (#7)"
g rev-parse HEAD > "$MRA_TEST_SHAS/mc7"
sed -i.bak 's/^seven4$/fixed4/' "$R/a.rb"; rm -f "$R/a.rb.bak"
GIT_COMMITTER_DATE=2026-08-12T00:00:00Z g commit -q -am "fix: seven4"
g rev-parse HEAD > "$MRA_TEST_SHAS/f1"
sed -i.bak -e 's/^seven5$/fixed5/' -e 's/^l6$/fixed6/' "$R/a.rb"; rm -f "$R/a.rb.bak"
GIT_COMMITTER_DATE=2026-08-13T00:00:00Z g commit -q -am "fix: seven5 and l6"
g rev-parse HEAD > "$MRA_TEST_SHAS/f2"
sed -i.bak 's/^l9$/fixed9/' "$R/a.rb"; rm -f "$R/a.rb.bak"
GIT_COMMITTER_DATE=2026-08-14T00:00:00Z g commit -q -am "fix: l9"
g rev-parse HEAD > "$MRA_TEST_SHAS/f3"

# 本機 clone：到 F3 為止。之後 remote 再多一個 F4，本機沒有。
git clone -q "$R" "$MRA_BACKTEST_WORKSPACE/blame-app"
# 本機 file:// 的 remote 預設不准用 sha 直接 fetch 未公告的物件；GitHub 准。
g config uploadpack.allowAnySHA1InWant true
sed -i.bak 's/^seven3$/fixed3/' "$R/a.rb"; rm -f "$R/a.rb.bak"
GIT_COMMITTER_DATE=2026-08-15T00:00:00Z g commit -q -am "fix: seven3 (remote only)"
g rev-parse HEAD > "$MRA_TEST_SHAS/f4"

cat > "$TMP/bin/gh" <<'SHIM'
#!/usr/bin/env bash
mc7="$(cat "$MRA_TEST_SHAS/mc7")"; f1="$(cat "$MRA_TEST_SHAS/f1")"
f2="$(cat "$MRA_TEST_SHAS/f2")"; f3="$(cat "$MRA_TEST_SHAS/f3")"
# 開關：merge commit 不在本機／fix commit 不在本機／fix commit 只在 origin，各自獨立
if [[ "${MRA_TEST_MC_MISSING:-0}" == "1" ]]; then mc7="0000000000000000000000000000000000000000"; fi
case "$*" in
  *"commits?since"*|*"commits?"*)
    extra=""
    if [[ "${MRA_TEST_FIX_MISSING:-0}" == "1" ]]; then
      extra=',{"sha":"1111111111111111111111111111111111111111","commit":{"message":"fix: not fetched yet"}}'
    fi
    if [[ "${MRA_TEST_FIX_REMOTE:-0}" == "1" ]]; then
      extra=",{\"sha\":\"$(cat "$MRA_TEST_SHAS/f4")\",\"commit\":{\"message\":\"fix: seven3 (remote only)\"}}"
    fi
    printf '[[{"sha":"%s","commit":{"message":"fix: seven4"}},{"sha":"%s","commit":{"message":"fix: seven5 and l6"}},{"sha":"%s","commit":{"message":"fix: l9"}}%s]]' \
      "$f1" "$f2" "$f3" "$extra" ;;
  *"pulls?state=closed"*)
    printf '[{"number":7,"merged_at":"2026-08-10T00:00:00Z","merge_commit_sha":"%s"}]' "$mc7" ;;
  *"pulls/7/files"*|*"commits/"*)
    # blame 模式不該再打這兩個端點：hunk 全走本機 git
    echo "UNEXPECTED_API_CALL $*" >&2; exit 1 ;;
esac
exit 0
SHIM
chmod +x "$TMP/bin/gh"; export PATH="$TMP/bin:$PATH"

errors=0; pass=0
ok()   { echo "PASS: $1"; pass=$((pass+1)); }
fail() { echo "FAIL: $1"; errors=$((errors+1)); }
eq()   { if [[ "$2" == "$3" ]]; then ok "$1"; else fail "$1 — expected [$2] got [$3]"; fi; }
has()  { case "$2" in *"$3"*) ok "$1" ;; *) fail "$1 — 沒看到「$3」：$2" ;; esac; }

C="$TMP/bench/candidates.json"

# --- 參數 ---------------------------------------------------------------------
bad="$(bash "$MRA_DIR/scripts/build-benchmark.sh" --repo acme/blame-app --attribution bogus 2>&1)"
eq "--attribution 不認得的值結束碼非 0" "1" "$?"
has "--attribution 不認得的值印 ATTRIBUTION_INVALID" "$bad" "ATTRIBUTION_INVALID"
help_out="$(bash "$MRA_DIR/scripts/build-benchmark.sh" --help 2>&1)"
has "--help 列出 --attribution" "$help_out" "--attribution"

# --- 主路徑 -------------------------------------------------------------------
out="$(bash "$MRA_DIR/scripts/build-benchmark.sh" --repo acme/blame-app --limit 10 --attribution blame 2>&1)"
eq "blame 模式結束碼 0" "0" "$?"
has "回報掃描筆數" "$out" "掃描 1 筆"
if [[ -s "$C" ]]; then ok "candidates.json 產出"; else fail "candidates.json 沒產出：$out"; fi
eq "一個候選 PR" "1" "$(jq 'length' "$C")"
eq "PR 編號" "7" "$(jq -r '.[0].pr' "$C")"
eq "候選標記 attribution=blame" "blame" "$(jq -r '.[0].attribution' "$C")"
eq "只留有歸因的 fix（F1 ratio 1.0、F2 ratio 0.5；F3 ratio 0 不收）" \
  "$(cat "$MRA_TEST_SHAS/f1" "$MRA_TEST_SHAS/f2" | jq -R . | jq -sc .)" \
  "$(jq -c '[.[0].fix_commits[].sha]' "$C")"
eq "fix 保留標題" "fix: seven4" "$(jq -r '.[0].fix_commits[0].message' "$C")"
eq "fix 記 gap_days（合併後 2 天）" "true" "$(jq '.[0].fix_commits[0].gap_days == 2' "$C")"
eq "第二個 fix 的 gap_days 是 3 天" "true" "$(jq '.[0].fix_commits[1].gap_days == 3' "$C")"
eq "hunk 帶路徑" "a.rb" "$(jq -r '.[0].fix_commits[0].hunks[0].path' "$C")"
eq "hunk 帶歸因比例" "1" "$(jq '.[0].fix_commits[0].hunks[0].ratio' "$C")"
eq "hunk 帶 PR 當時的行號" "[4]" "$(jq -c '.[0].fix_commits[0].hunks[0].head_lines' "$C")"
eq "hunk 帶新檔側區間" "[4,4]" "$(jq -c '.[0].fix_commits[0].hunks[0] | [.new_from, .new_to]' "$C")"
eq "F2 的 hunk ratio 0.5" "0.5" "$(jq '.[0].fix_commits[1].hunks[0].ratio' "$C")"
eq "blame 模式沒有 overlaps 欄位" "null" "$(jq -c '.[0].fix_commits[0].overlaps' "$C")"
eq "confirmed 預設 null" "null" "$(jq -r '.[0].confirmed' "$C")"
eq "expected_findings 預設空" "0" "$(jq '.[0].expected_findings | length' "$C")"

# --- 門檻可調：MRA_BACKTEST_BLAME_MIN_RATIO=0.6 時 F2（0.5）不收 -----------------
rm -f "$C"
MRA_BACKTEST_BLAME_MIN_RATIO=0.6 bash "$MRA_DIR/scripts/build-benchmark.sh" --repo acme/blame-app --limit 10 --attribution blame >/dev/null 2>&1
eq "門檻 0.6 時只剩 F1" "$(jq -R . "$MRA_TEST_SHAS/f1" | jq -sc .)" "$(jq -c '[.[0].fix_commits[].sha]' "$C")"

# --- 重跑保留人工結果（合併規則跟交集模式共用，但 blame 模式自己也要驗一次）---
jq '.[0].confirmed = true | .[0].expected_findings = [{"path":"a.rb","line":4}]' "$C" > "$C.tmp" && mv "$C.tmp" "$C"
bash "$MRA_DIR/scripts/build-benchmark.sh" --repo acme/blame-app --limit 10 --attribution blame >/dev/null 2>&1
eq "重跑保留 confirmed" "true" "$(jq -r '.[0].confirmed' "$C")"
eq "重跑保留 expected_findings" '[{"path":"a.rb","line":4}]' "$(jq -c '.[0].expected_findings' "$C")"

# --- 本機 clone 不存在：直接失敗，不碰 candidates.json --------------------------
before="$(cat "$C")"
missing="$(MRA_BACKTEST_WORKSPACE="$TMP/nowhere" bash "$MRA_DIR/scripts/build-benchmark.sh" --repo acme/blame-app --limit 10 --attribution blame 2>&1)"
eq "本機 clone 不存在結束碼非 0" "1" "$?"
has "本機 clone 不存在印 LOCAL_REPO_MISSING" "$missing" "LOCAL_REPO_MISSING"
eq "本機 clone 不存在時 candidates.json 原封不動" "$before" "$(cat "$C")"

# --- merge commit 不在本機：算 PR lookup 失敗，LOOKUP_FAILED、不碰檔案 ------------
mc_missing="$(MRA_TEST_MC_MISSING=1 bash "$MRA_DIR/scripts/build-benchmark.sh" --repo acme/blame-app --limit 10 --attribution blame 2>&1)"
eq "merge commit 不在本機結束碼非 0" "1" "$?"
has "merge commit 不在本機印 LOOKUP_FAILED（PR 層 1 筆）" "$mc_missing" "LOOKUP_FAILED	acme/blame-app	1	0	1"
has "merge commit 不在本機提示要 fetch" "$mc_missing" "LOCAL_COMMIT_MISSING"
eq "merge commit 不在本機時 candidates.json 原封不動" "$before" "$(cat "$C")"

# --- fix commit 不在本機：算 commit lookup 失敗，不能當成「沒有 hunk」-------------
fix_missing="$(MRA_TEST_FIX_MISSING=1 bash "$MRA_DIR/scripts/build-benchmark.sh" --repo acme/blame-app --limit 10 --attribution blame 2>&1)"
eq "fix commit 不在本機結束碼非 0" "1" "$?"
has "fix commit 不在本機印 LOOKUP_FAILED（commit 層 1 筆）" "$fix_missing" "LOOKUP_FAILED	acme/blame-app	0	1	1"
eq "fix commit 不在本機時 candidates.json 原封不動" "$before" "$(cat "$C")"

# --- fix commit 只在 origin：產生器自己用 sha fetch 一次，抓到就照常算 ---------
if git -C "$MRA_BACKTEST_WORKSPACE/blame-app" cat-file -e "$(cat "$MRA_TEST_SHAS/f4")^{commit}" 2>/dev/null; then
  fail "前置：F4 一開始不該在本機 clone"
else
  ok "前置：F4 一開始不在本機 clone"
fi
remote_out="$(MRA_TEST_FIX_REMOTE=1 bash "$MRA_DIR/scripts/build-benchmark.sh" --repo acme/blame-app --limit 10 --attribution blame 2>&1)"
eq "fix commit 只在 origin 時結束碼 0" "0" "$?"
eq "F4 被 fetch 下來並成為候選的 fix" "1" \
  "$(jq --arg s "$(cat "$MRA_TEST_SHAS/f4")" '[.[0].fix_commits[] | select(.sha == $s)] | length' "$C")"
eq "F4 的 hunk 歸到 PR #7、PR 當時是第 3 行" "[3]" \
  "$(jq -c --arg s "$(cat "$MRA_TEST_SHAS/f4")" '.[0].fix_commits[] | select(.sha == $s) | .hunks[0].head_lines' "$C")"
case "$remote_out" in
  *LOCAL_COMMIT_MISSING*) fail "抓得到的 commit 不該印 LOCAL_COMMIT_MISSING：$remote_out" ;;
  *) ok "抓得到的 commit 不印 LOCAL_COMMIT_MISSING" ;;
esac

echo "---"; echo "Passed: $pass"; echo "Failed: $errors"
exit $((errors > 0 ? 1 : 0))
