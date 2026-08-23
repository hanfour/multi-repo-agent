#!/usr/bin/env bash
# scripts/build-benchmark.sh：--until 旗標端到端傳到 backtest_merged_prs
# (lib/backtest-groundtruth.sh)，正確依 created_at 過濾候選 PR(Ruling 27)。
#
# 獨立於 tests/test_build_benchmark.sh 之外自成一支：那支檔案裡
# pulls?state=closed 的 gh stub 被多個既有失敗注入情境共用(同一份 PR
# 清單、同一個 MRA_BENCHMARK_DIR)，往那份共用清單多加一筆 PR 會連帶影響
# 好幾組已經校準過期望值的斷言。這裡用完全獨立的 TMP／gh stub／
# MRA_BENCHMARK_DIR，兩筆 PR 各自改不同檔案，避免交叉配對出假候選。
set -uo pipefail
MRA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export MRA_BENCHMARK_DIR="$TMP/bench"
mkdir -p "$TMP/bin"

# 4801：created_at 2026-08-01，改 app/a.rb，一筆重疊的 fix commit(fix4801)。
# 4802：created_at 2026-08-10，改 app/b.rb，一筆重疊的 fix commit(fix4802)。
# 兩筆 PR 各自的 fix commit 只改自己的檔案，避免其中一筆的候選判定意外
# 命中另一筆 PR 的區間。
cat > "$TMP/bin/gh" <<'SHIM'
#!/usr/bin/env bash
case "$*" in
  *"pulls/4801/files"*)
    printf '%s' '[{"filename":"app/a.rb","patch":"@@ -10,5 +10,5 @@ def x\n y"}]' ;;
  *"pulls/4802/files"*)
    printf '%s' '[{"filename":"app/b.rb","patch":"@@ -20,5 +20,5 @@ def z\n w"}]' ;;
  *"commits/fix4801"*)
    printf '%s' '{"files":[{"filename":"app/a.rb","patch":"@@ -11,2 +11,4 @@ def x\n p"}]}' ;;
  *"commits/fix4802"*)
    printf '%s' '{"files":[{"filename":"app/b.rb","patch":"@@ -21,2 +21,4 @@ def z\n q"}]}' ;;
  *"commits?since"*|*"commits?"*)
    # 陣列的陣列：真實的 `gh api --paginate --slurp` 就是這個形狀，一頁一個元素。
    printf '%s' '[[{"sha":"fix4801","commit":{"message":"fix(a): overlapping fix for 4801"}},
                   {"sha":"fix4802","commit":{"message":"fix(b): overlapping fix for 4802"}}]]' ;;
  *"pulls?state=closed"*)
    printf '%s' '[{"number":4802,"created_at":"2026-08-10T00:00:00Z","merged_at":"2026-08-11T00:00:00Z","merge_commit_sha":"own4802"},
                  {"number":4801,"created_at":"2026-08-01T00:00:00Z","merged_at":"2026-08-02T00:00:00Z","merge_commit_sha":"own4801"}]' ;;
esac
exit 0
SHIM
chmod +x "$TMP/bin/gh"; export PATH="$TMP/bin:$PATH"

errors=0; pass=0
ok()   { echo "PASS: $1"; pass=$((pass+1)); }
fail() { echo "FAIL: $1"; errors=$((errors+1)); }
eq()   { if [[ "$2" == "$3" ]]; then ok "$1"; else fail "$1 — expected [$2] got [$3]"; fi; }

C="$MRA_BENCHMARK_DIR/candidates.json"

# --- 案例 1：沒給 --until，行為與現在一致，兩筆都收 ------------------------
bash "$MRA_DIR/scripts/build-benchmark.sh" --repo acme/rails-app-1 --limit 10 >/dev/null 2>&1
rc1=$?
eq "沒給 --until：退出碼 0" "0" "$rc1"
eq "沒給 --until：兩筆 PR 都收(4801、4802)" "2" "$(jq 'length' "$C")"
eq "沒給 --until：4801 有被收" "1" \
  "$(jq '[.[] | select(.pr == 4801)] | length' "$C")"
eq "沒給 --until：4802 有被收" "1" \
  "$(jq '[.[] | select(.pr == 4802)] | length' "$C")"

# --- 案例 2：--until 設在兩筆 PR 之間，只收 4801(4802 建立在 --until 之後) -
rm -f "$C"
bash "$MRA_DIR/scripts/build-benchmark.sh" --repo acme/rails-app-1 --limit 10 \
  --until 2026-08-05T00:00:00Z >/dev/null 2>&1
rc2=$?
eq "給 --until=08-05：退出碼 0" "0" "$rc2"
eq "給 --until=08-05：只收 4801 一筆(4802 建立於 08-10，晚於 until)" "1" \
  "$(jq 'length' "$C")"
eq "給 --until=08-05：收到的是 4801" "4801" "$(jq -r '.[0].pr' "$C")"

# --- 案例 3：--until 設在兩筆都之後，兩筆都收(驗證不是「只要有給就砍半」) --
rm -f "$C"
bash "$MRA_DIR/scripts/build-benchmark.sh" --repo acme/rails-app-1 --limit 10 \
  --until 2026-09-01T00:00:00Z >/dev/null 2>&1
eq "給 --until=09-01(晚於兩筆)：兩筆都收" "2" "$(jq 'length' "$C")"

# --- 案例 4：--until 缺值，用法錯誤要擋下來，不能吃掉下一個參數 ------------
bash "$MRA_DIR/scripts/build-benchmark.sh" --repo acme/rails-app-1 --until >/dev/null 2>&1
eq "--until 缺值結束碼非 0" "1" "$?"

echo "---"; echo "Passed: $pass"; echo "Failed: $errors"
exit $((errors > 0 ? 1 : 0))
