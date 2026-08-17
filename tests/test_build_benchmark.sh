#!/usr/bin/env bash
# 基準集候選建構 (scripts/build-benchmark.sh)。
set -uo pipefail
MRA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export MRA_BENCHMARK_DIR="$TMP/bench"
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
                  {"sha":"bbb222","commit":{"message":"fix(z): unrelated file"}}]' ;;
  *"pulls?state=closed"*)
    printf '%s' '[{"number":4919,"merged_at":"2026-08-10T09:09:52Z","merge_commit_sha":"own999"}]' ;;
esac
exit 0
SHIM
chmod +x "$TMP/bin/gh"; export PATH="$TMP/bin:$PATH"

errors=0; pass=0
ok()   { echo "PASS: $1"; pass=$((pass+1)); }
fail() { echo "FAIL: $1"; errors=$((errors+1)); }
eq()   { if [[ "$2" == "$3" ]]; then ok "$1"; else fail "$1 — expected [$2] got [$3]"; fi; }

# 參數解析：三種情況都不打 gh，純粹測 CLI 本身的行為。
help_out="$(bash "$MRA_DIR/scripts/build-benchmark.sh" --help 2>&1)"
eq "--help 結束碼 0" "0" "$?"
if [[ "$help_out" == *"用法"* ]]; then ok "--help 印用法"; else fail "--help 印用法 — 沒看到「用法」：$help_out"; fi

bash "$MRA_DIR/scripts/build-benchmark.sh" --bogus-flag >/dev/null 2>&1
eq "未知參數結束碼非 0" "1" "$?"

# --repo 缺值：不能吃掉下一個參數當成 repo 名稱，也不能靜默地用空字串繼續跑。
bash "$MRA_DIR/scripts/build-benchmark.sh" --repo >/dev/null 2>&1
eq "缺 --repo 值結束碼非 0" "1" "$?"

bash "$MRA_DIR/scripts/build-benchmark.sh" --repo acme/rails-app-1 --limit 10 >/dev/null 2>&1
eq "退出碼 0" "0" "$?"

C="$TMP/bench/candidates.json"
if [[ -s "$C" ]]; then ok "candidates.json 產出"; else fail "candidates.json 沒產出"; fi
eq "一個候選 PR"     "1"          "$(jq 'length' "$C")"
eq "PR 編號"         "4919"       "$(jq -r '.[0].pr' "$C")"
eq "只留有重疊的 fix" '["aaa111"]' "$(jq -c '[.[0].fix_commits[].sha]' "$C")"
eq "重疊落在 a.rb"    '"app/a.rb"' "$(jq -c '.[0].fix_commits[0].overlaps[0].path' "$C")"
eq "confirmed 預設 null" "null"    "$(jq -r '.[0].confirmed' "$C")"
eq "expected_findings 預設空" "0"  "$(jq '.[0].expected_findings | length' "$C")"

# 重跑不覆蓋已填的 confirmed，也不覆蓋已填的 expected_findings——兩個欄位是
# 分開的人工填值，各自要有自己的斷言，才不會其中一個漏掉合併邏輯也測不出來。
jq '.[0].confirmed = true | .[0].expected_findings = ["SQL injection risk"]' "$C" \
  > "$C.tmp" && mv "$C.tmp" "$C"
bash "$MRA_DIR/scripts/build-benchmark.sh" --repo acme/rails-app-1 --limit 10 >/dev/null 2>&1
eq "重跑保留人工結果" "true" "$(jq -r '.[0].confirmed' "$C")"
eq "重跑保留 expected_findings" '["SQL injection risk"]' "$(jq -c '.[0].expected_findings' "$C")"

# candidates.json 是所有 repo 共用的同一個檔案。幫 acme/rails-app-1 重新建一次，不能
# 連帶動到 acme/nest-monorepo-2.0 的列——這是舊版「用這次的結果當合併基底」會
# 犯的錯：這次沒跑到的 repo／PR 全部被當成不存在而刪掉。
#
# 故意用同一個 PR 編號（4919）：如果合併鍵只看 pr、不看 repo，$old 的查表
# 會把兩個 repo 的列撞成同一個鍵，光看「repo B 的列還在不在」測不出這個錯
# （兩種錯的症狀都是「repo B 的列不見了」），還要另外驗 repo A 自己的欄位
# 有沒有被撞鍵污染，才分得出「整列被刪掉」跟「鍵撞在一起」是兩個不同的錯。
jq '. + [{"repo":"acme/nest-monorepo-2.0","pr":4919,"merged_at":"2026-01-01T00:00:00Z",
          "fix_commits":[],"confirmed":true,"expected_findings":["dup pr number test"]}]' \
  "$C" > "$C.tmp" && mv "$C.tmp" "$C"
bash "$MRA_DIR/scripts/build-benchmark.sh" --repo acme/rails-app-1 --limit 10 >/dev/null 2>&1
eq "跨 repo 隔離：兩個 repo 的列都在" "2" "$(jq 'length' "$C")"
eq "跨 repo 隔離：repo B 的 confirmed 不受影響" "true" \
  "$(jq -r '.[] | select(.repo == "acme/nest-monorepo-2.0" and .pr == 4919) | .confirmed' "$C")"
eq "跨 repo 隔離：repo B 的 expected_findings 不受影響" '["dup pr number test"]' \
  "$(jq -c '.[] | select(.repo == "acme/nest-monorepo-2.0" and .pr == 4919) | .expected_findings' "$C")"
eq "跨 repo 隔離：合鍵含 repo（repo A 自己的欄位沒被同號的 repo B 污染）" '["SQL injection risk"]' \
  "$(jq -c '.[] | select(.repo == "acme/rails-app-1" and .pr == 4919) | .expected_findings' "$C")"

# 合併輸入若已損毀（不是合法 JSON），要清掉壞掉的 candidates.json 並以非 0
# 結束，不能留著讓下一輪看起來像是延用上一輪的結果，也不能留下沒搬成功的
# .tmp。
printf 'not valid json' > "$C"
bash "$MRA_DIR/scripts/build-benchmark.sh" --repo acme/rails-app-1 --limit 10 >/dev/null 2>&1
rc=$?
eq "合併失敗結束碼非 0" "1" "$rc"
if [[ ! -e "$C" ]]; then ok "合併失敗清掉損毀檔"; else fail "合併失敗清掉損毀檔 — 舊檔還在"; fi
if [[ ! -e "$C.tmp" ]]; then ok "合併失敗不留 tmp"; else fail "合併失敗不留 tmp — tmp 還在"; fi

echo "---"; echo "Passed: $pass"; echo "Failed: $errors"
exit $((errors > 0 ? 1 : 0))
