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
    # 另一個獨立的開關：只讓 pr-ranges 這條 lookup 失敗，commits 端點正常。
    # 用來把 A（fix-commits 失敗）跟 B（pr-ranges 失敗）測成兩條不會互相
    # 觸發的路徑——fix_commits 失敗會在到達這裡之前就 continue 掉。
    if [[ "${MRA_TEST_PRFILES_FAIL:-0}" == "1" ]]; then exit 1; fi
    printf '%s' '[{"filename":"app/a.rb","patch":"@@ -92,7 +92,7 @@ def update\n x"},
                  {"filename":"app/b.rb","patch":"@@ -10,5 +10,5 @@ def x\n y"}]' ;;
  *"commits/aaa111"*)
    # 第三個獨立開關：只讓單一 commit 的查詢（內層、每個 fix commit 各一次）
    # 失敗，commits 列表跟 pulls 都正常——這是目前唯一會漏收候選、卻完全
    # 沒有痕跡的形狀，跟外層兩個開關各自獨立、不會互相觸發。
    if [[ "${MRA_TEST_COMMITSHA_FAIL:-0}" == "1" ]]; then exit 1; fi
    printf '%s' '{"files":[{"filename":"app/a.rb","patch":"@@ -95,2 +95,4 @@ def update\n z"}]}' ;;
  *"commits/bbb222"*)
    if [[ "${MRA_TEST_COMMITSHA_FAIL:-0}" == "1" ]]; then exit 1; fi
    printf '%s' '{"files":[{"filename":"app/c.rb","patch":"@@ -1,2 +1,2 @@\n w"}]}' ;;
  *"commits?since"*|*"commits?"*)
    # 模擬真實事故：org 的 /commits 端點局部中斷（404），/pulls 端點不受影響。
    # 開關用環境變數，其他測試不用改就自動不受影響。
    if [[ "${MRA_TEST_COMMITS_FAIL:-0}" == "1" ]]; then exit 1; fi
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

run1_out="$(bash "$MRA_DIR/scripts/build-benchmark.sh" --repo acme/rails-app-1 --limit 10 2>&1)"
eq "退出碼 0" "0" "$?"
# 成功時也要回報掃了幾筆 PR：掃 3 筆跟掃 100 筆不能印出同一種乾淨結尾。
if [[ "$run1_out" == *"掃描 1 筆"* ]]; then
  ok "成功時回報掃描筆數"
else
  fail "成功時回報掃描筆數 — stdout: $run1_out"
fi

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

# org 的 /commits 端點局部中斷（404），/pulls 端點正常——這是真實發生過的
# 事故形狀，不是編造的邊界案例。backtest_fix_commits 對每一筆 PR 都會失敗，
# 這跟「這個 repo 本來就沒有候選」是兩回事：混在一起會讓整個 repo 的候選
# 悄悄消失，還印出跟「沒有候選」一模一樣的乾淨結尾。用一個新 repo 名稱測，
# 確定：(1) 這個 repo 不會有任何候選列被寫進去，(2) 檔案裡其他每一個位元組
# ——包括別的 repo 的列、包括已經填好的 confirmed——完全不受影響。
cp "$C" "$TMP/candidates.before"
MRA_TEST_COMMITS_FAIL=1 bash "$MRA_DIR/scripts/build-benchmark.sh" \
  --repo acme/nest-app-2 --limit 10 >"$TMP/lookup_fail.out" 2>"$TMP/lookup_fail.err"
rc=$?
eq "lookup 失敗結束碼非 0" "1" "$rc"

lf_line="$(grep '^LOOKUP_FAILED' "$TMP/lookup_fail.err" || true)"
if [[ -n "$lf_line" ]]; then
  ok "LOOKUP_FAILED 有印出"
else
  fail "LOOKUP_FAILED 有印出 — stderr: $(cat "$TMP/lookup_fail.err")"
fi
IFS=$'\t' read -r _ lf_repo lf_outer lf_inner _ <<< "$lf_line"
eq "LOOKUP_FAILED 標出 repo" "acme/nest-app-2" "$lf_repo"
# fix-commits 是外層 lookup，失敗要算進 PR 層的計數，不能混進內層（commit
# 層）的計數——這條連同 pr-ranges 那組、inner 那組一起，才能證明報告真的
# 分得出外層跟內層失敗是哪一種。
eq "LOOKUP_FAILED 標出外層（PR lookup）失敗筆數" "1" "$lf_outer"
eq "LOOKUP_FAILED 標出內層（commit lookup）失敗筆數" "0" "$lf_inner"

eq "lookup 失敗不寫入該 repo 的候選列" "0" \
  "$(jq '[.[] | select(.repo == "acme/nest-app-2")] | length' "$C")"
if diff -q "$TMP/candidates.before" "$C" >/dev/null 2>&1; then
  ok "lookup 失敗完全不動舊檔（逐位元組相同）"
else
  fail "lookup 失敗完全不動舊檔（逐位元組相同） — 檔案被動過"
fi
# 失敗時合併／寫檔那段完全不該執行到——不能只看檔案內容剛好沒變（這個
# fixture 剛好 0 個新候選，光比對內容測不出「其實還是走到寫檔那段」），
# 要直接驗證成功摘要那幾行完全沒印出來。
if [[ "$(cat "$TMP/lookup_fail.out")" != *"候選（累計"* ]]; then
  ok "lookup 失敗不印出成功摘要（沒走到合併／寫檔那段）"
else
  fail "lookup 失敗不印出成功摘要（沒走到合併／寫檔那段） — stdout: $(cat "$TMP/lookup_fail.out")"
fi

# 同一個事故形狀，但換成只讓 pr-ranges 這條 lookup 失敗（commits 端點正常）。
# fix-commits 失敗會在還沒碰到 pr-ranges 之前就 continue 掉，所以上面那個
# 測試測不到「pr-ranges 失敗」這條路徑有沒有一樣被算成失敗，需要另一個獨立
# 案例才分得出兩條路徑是不是各自都有處理，不是只處理了其中一條。
cp "$C" "$TMP/candidates.before2"
MRA_TEST_PRFILES_FAIL=1 bash "$MRA_DIR/scripts/build-benchmark.sh" \
  --repo acme/bl-app --limit 10 >"$TMP/lookup_fail2.out" 2>"$TMP/lookup_fail2.err"
rc=$?
eq "lookup 失敗（pr-ranges）結束碼非 0" "1" "$rc"

lf2_line="$(grep '^LOOKUP_FAILED' "$TMP/lookup_fail2.err" || true)"
if [[ -n "$lf2_line" ]]; then
  ok "lookup 失敗（pr-ranges）LOOKUP_FAILED 有印出"
else
  fail "lookup 失敗（pr-ranges）LOOKUP_FAILED 有印出 — stderr: $(cat "$TMP/lookup_fail2.err")"
fi
IFS=$'\t' read -r _ lf2_repo lf2_outer lf2_inner _ <<< "$lf2_line"
eq "lookup 失敗（pr-ranges）標出 repo" "acme/bl-app" "$lf2_repo"
eq "lookup 失敗（pr-ranges）標出外層（PR lookup）失敗筆數" "1" "$lf2_outer"
eq "lookup 失敗（pr-ranges）標出內層（commit lookup）失敗筆數" "0" "$lf2_inner"

eq "lookup 失敗（pr-ranges）不寫入該 repo 的候選列" "0" \
  "$(jq '[.[] | select(.repo == "acme/bl-app")] | length' "$C")"
if diff -q "$TMP/candidates.before2" "$C" >/dev/null 2>&1; then
  ok "lookup 失敗（pr-ranges）完全不動舊檔（逐位元組相同）"
else
  fail "lookup 失敗（pr-ranges）完全不動舊檔（逐位元組相同） — 檔案被動過"
fi

# 第三個事故形狀：commits 列表跟 pulls 都正常，只有單一 commit 的查詢（內層、
# 迴圈裡對每個 fix commit 各查一次）失敗。這是三個開關裡最隱蔽的一種——
# 原本的 || continue 只會讓這個 fix commit 被當成「沒有重疊」，PR 本身的
# 判斷照樣往下走，不會有任何非 0 結束碼、也不會有任何訊息，一個真正有缺陷
# 的候選就這樣悄悄從基準集消失，比整個 repo 交白卷還難發現。
# fixes = [aaa111, bbb222] 兩筆，開關讓兩個 commits/<sha> 端點都失敗，內層
# 失敗筆數應該是 2（每個 fix commit 各算一次，不是每個 PR 算一次）。
cp "$C" "$TMP/candidates.before3"
MRA_TEST_COMMITSHA_FAIL=1 bash "$MRA_DIR/scripts/build-benchmark.sh" \
  --repo acme/lg-app --limit 10 >"$TMP/lookup_fail3.out" 2>"$TMP/lookup_fail3.err"
rc=$?
eq "lookup 失敗（commit-ranges）結束碼非 0" "1" "$rc"

lf3_line="$(grep '^LOOKUP_FAILED' "$TMP/lookup_fail3.err" || true)"
if [[ -n "$lf3_line" ]]; then
  ok "lookup 失敗（commit-ranges）LOOKUP_FAILED 有印出"
else
  fail "lookup 失敗（commit-ranges）LOOKUP_FAILED 有印出 — stderr: $(cat "$TMP/lookup_fail3.err")"
fi
IFS=$'\t' read -r _ lf3_repo lf3_outer lf3_inner _ <<< "$lf3_line"
eq "lookup 失敗（commit-ranges）標出 repo" "acme/lg-app" "$lf3_repo"
# 這兩條是這一輪修法的核心：內層失敗不能算進外層的計數，外層要維持 0。
eq "lookup 失敗（commit-ranges）標出外層（PR lookup）失敗筆數" "0" "$lf3_outer"
eq "lookup 失敗（commit-ranges）標出內層（commit lookup）失敗筆數" "2" "$lf3_inner"

eq "lookup 失敗（commit-ranges）不寫入該 repo 的候選列" "0" \
  "$(jq '[.[] | select(.repo == "acme/lg-app")] | length' "$C")"
if diff -q "$TMP/candidates.before3" "$C" >/dev/null 2>&1; then
  ok "lookup 失敗（commit-ranges）完全不動舊檔（逐位元組相同）"
else
  fail "lookup 失敗（commit-ranges）完全不動舊檔（逐位元組相同） — 檔案被動過"
fi
if [[ "$(cat "$TMP/lookup_fail3.out")" != *"候選（累計"* ]]; then
  ok "lookup 失敗（commit-ranges）不印出成功摘要（沒走到合併／寫檔那段）"
else
  fail "lookup 失敗（commit-ranges）不印出成功摘要（沒走到合併／寫檔那段） — stdout: $(cat "$TMP/lookup_fail3.out")"
fi

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
