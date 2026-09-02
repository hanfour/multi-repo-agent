#!/usr/bin/env bash
# 基準集候選建構 (scripts/build-benchmark.sh)。
set -uo pipefail
MRA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export MRA_BENCHMARK_DIR="$TMP/bench"
mkdir -p "$TMP/bin"
cat > "$TMP/bin/gh" <<'SHIM'
#!/usr/bin/env bash
# 有給 MRA_TEST_GH_CALLS 就把每次呼叫的完整參數記下來，讓測試能檢查 URL。
[[ -n "${MRA_TEST_GH_CALLS:-}" ]] && echo "$*" >> "$MRA_TEST_GH_CALLS"
case "$*" in
  *"pulls/4919/files"*)
    # 另一個獨立的開關：只讓 pr-ranges 這條 lookup 失敗，commits 端點正常。
    # 用來把 A（fix-commits 失敗）跟 B（pr-ranges 失敗）測成兩條不會互相
    # 觸發的路徑——fix_commits 失敗會在到達這裡之前就 continue 掉。
    if [[ "${MRA_TEST_PRFILES_FAIL:-0}" == "1" ]]; then exit 1; fi
    # 陣列的陣列：真實的 `gh api --paginate --slurp` 就是這個形狀，一頁一個
    # 元素。backtest_pr_ranges 現在要分頁（PR 可能改到超過 100 個檔案），
    # 所以 stub 也要回這個形狀，否則測的是一個不存在的回應。
    printf '%s' '[[{"filename":"app/a.rb","patch":"@@ -92,7 +92,7 @@ def update\n x"},
                   {"filename":"app/b.rb","patch":"@@ -10,5 +10,5 @@ def x\n y"}]]' ;;
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
    # 陣列的陣列：真實的 `gh api --paginate --slurp` 就是這個形狀，一頁一個元素。
    printf '%s' '[[{"sha":"own999","commit":{"message":"fix(x): the PR itself (#4919)"}},
                   {"sha":"aaa111","commit":{"message":"fix(y): overlapping fix"}},
                   {"sha":"bbb222","commit":{"message":"fix(z): unrelated file"}}]]' ;;
  *"pulls?state=closed"*)
    # 第四個獨立開關：讓 PR 列表本身（/pulls）失敗，commits／pr-files 都
    # 正常。跟另外三個開關獨立、不會互相觸發。
    if [[ "${MRA_TEST_PULLS_FAIL:-0}" == "1" ]]; then exit 1; fi
    case "$*" in
      # 專門給「合法空 repo」測試用：查得到列表，列表本身是空的，
      # 不能跟上面的 PULLS_FAIL 開關共用同一種結束方式。
      *"repos/acme/empty-repo/"*) printf '%s' '[]' ;;
      *) printf '%s' '[{"number":4919,"created_at":"2026-08-05T00:00:00Z","merged_at":"2026-08-10T09:09:52Z","merge_commit_sha":"own999"}]' ;;
    esac ;;
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

# 其餘三個帶值的旗標也一樣不能吃掉下一個參數、也不能死在 set -u 的
# 「$2: 未綁定的變數」——那種訊息指向行號，不指向使用者打錯的旗標。
for _flag in --limit --days --until --since; do
  _out="$(bash "$MRA_DIR/scripts/build-benchmark.sh" "$_flag" 2>&1)"; _rc=$?
  eq "缺 ${_flag} 值結束碼非 0" "1" "$_rc"
  case "$_out" in
    *"需要接一個值"*) ok "缺 ${_flag} 值印出用法" ;;
    *) fail "缺 ${_flag} 值該印用法，實際是：$_out" ;;
  esac
done

# --limit 會變成 GitHub 的 per_page，上限 100。超過的話 API 靜默回 100 筆，
# 分母比要求的少而且沒有任何訊號——那是一個看不出來的錯誤分母。
limit_out="$(bash "$MRA_DIR/scripts/build-benchmark.sh" --repo acme/rails-app-1 --limit 300 2>&1)"
eq "--limit 超過 100 結束碼非 0" "1" "$?"
case "$limit_out" in
  LIMIT_TOO_LARGE*) ok "--limit 超過 100 印出 LIMIT_TOO_LARGE" ;;
  *) fail "缺 LIMIT_TOO_LARGE：$limit_out" ;;
esac
limit_bad="$(bash "$MRA_DIR/scripts/build-benchmark.sh" --repo acme/rails-app-1 --limit abc 2>&1)"
eq "--limit 非數字結束碼非 0" "1" "$?"
case "$limit_bad" in
  LIMIT_INVALID*) ok "--limit 非數字印出 LIMIT_INVALID" ;;
  *) fail "缺 LIMIT_INVALID：$limit_bad" ;;
esac

# --days 一路傳到 backtest_window_end 的 python3 timedelta(days=int(...))，
# 非數字會以一段 Python traceback 收場，而不是一句講得清楚的用法錯誤。
days_bad="$(bash "$MRA_DIR/scripts/build-benchmark.sh" --repo acme/rails-app-1 --days abc 2>&1)"
eq "--days 非數字結束碼非 0" "1" "$?"
case "$days_bad" in
  DAYS_INVALID*) ok "--days 非數字印出 DAYS_INVALID" ;;
  *) fail "缺 DAYS_INVALID：$days_bad" ;;
esac
case "$days_bad" in
  *Traceback*) fail "--days 非數字不該噴 Python traceback" ;;
  *) ok "--days 非數字不噴 Python traceback" ;;
esac

# --since：掃「這個時間點之後建立的全部 PR」，走逐頁翻的路徑（見
# lib/backtest-groundtruth.sh）。格式不對要在打 API 之前就擋下來：ISO 8601
# 字串是拿來跟 created_at 做字串比較的，「2025-9-2」這種會靜默比錯。
since_bad="$(bash "$MRA_DIR/scripts/build-benchmark.sh" --repo acme/rails-app-1 --since 2025-9-2 2>&1)"
eq "--since 格式不對結束碼非 0" "1" "$?"
case "$since_bad" in
  SINCE_INVALID*) ok "--since 格式不對印出 SINCE_INVALID" ;;
  *) fail "缺 SINCE_INVALID：$since_bad" ;;
esac
if [[ "$(bash "$MRA_DIR/scripts/build-benchmark.sh" --help 2>&1)" == *"--since"* ]]; then
  ok "--help 提到 --since"
else
  fail "--help 沒提到 --since"
fi
export MRA_TEST_GH_CALLS="$TMP/gh-calls.log"; : > "$MRA_TEST_GH_CALLS"
since_out="$(bash "$MRA_DIR/scripts/build-benchmark.sh" --repo acme/rails-app-1 --since 2026-08-01T00:00:00Z 2>&1)"
eq "--since 結束碼 0" "0" "$?"
if [[ "$since_out" == *"掃描 1 筆"* ]]; then ok "--since 之後建立的 PR 有掃到"; else fail "--since 之後建立的 PR 該掃到：$since_out"; fi
eq "--since 走逐頁翻的 URL（帶 &page=1）" "1" "$(grep -c 'pulls?state=closed.*&page=1' "$MRA_TEST_GH_CALLS")"
: > "$MRA_TEST_GH_CALLS"
since_out="$(bash "$MRA_DIR/scripts/build-benchmark.sh" --repo acme/rails-app-1 --since 2026-08-10T00:00:00Z 2>&1)"
if [[ "$since_out" == *"沒有 merged PR"* ]]; then ok "--since 之前建立的 PR 不掃"; else fail "--since 之前建立的 PR 不該掃：$since_out"; fi
: > "$MRA_TEST_GH_CALLS"
bash "$MRA_DIR/scripts/build-benchmark.sh" --repo acme/rails-app-1 --limit 10 >/dev/null 2>&1
eq "沒給 --since 時 URL 不帶 &page=（行為不變）" "0" "$(grep -c '&page=' "$MRA_TEST_GH_CALLS")"
unset MRA_TEST_GH_CALLS
rm -f "$TMP/bench/candidates.json"

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

# 第四個、也是後果最重的事故形狀：PR 列表本身（/pulls）讀不到，commits／
# pr-files 都正常。這一版事故剛好是 /pulls 正常、/commits 中斷；如果反過來，
# 外層／內層兩個計數器根本還沒開始跑，整個 repo 連候選名單都生不出來，卻
# 只會印出跟「這個 repo 真的沒有已合併 PR」一模一樣的訊息——這是三個既有
# 開關都測不到的第四種形狀。
cp "$C" "$TMP/candidates.before4"
MRA_TEST_PULLS_FAIL=1 bash "$MRA_DIR/scripts/build-benchmark.sh" \
  --repo acme/wh-app --limit 10 >"$TMP/lookup_fail4.out" 2>"$TMP/lookup_fail4.err"
rc=$?
eq "lookup 失敗（pulls 列表）結束碼非 0" "1" "$rc"

lf4_line="$(grep '^LOOKUP_FAILED' "$TMP/lookup_fail4.err" || true)"
if [[ -n "$lf4_line" ]]; then
  ok "lookup 失敗（pulls 列表）LOOKUP_FAILED 有印出"
else
  fail "lookup 失敗（pulls 列表）LOOKUP_FAILED 有印出 — stderr: $(cat "$TMP/lookup_fail4.err")"
fi
IFS=$'\t' read -r _ lf4_repo lf4_marker <<< "$lf4_line"
eq "lookup 失敗（pulls 列表）標出 repo" "acme/wh-app" "$lf4_repo"
# 這一條是本輪的核心：形狀要跟 PR／commit 層級的 LOOKUP_FAILED 不一樣
# （用 "listing" 這個字，不是數字），操作者一看就知道是 repo 列表本身
# 讀不到，不是「某些 PR／commit 查不到」，要往完全不同的地方查。
eq "lookup 失敗（pulls 列表）標出 listing 標記" "listing" "$lf4_marker"

eq "lookup 失敗（pulls 列表）不寫入該 repo 的候選列" "0" \
  "$(jq '[.[] | select(.repo == "acme/wh-app")] | length' "$C")"
if diff -q "$TMP/candidates.before4" "$C" >/dev/null 2>&1; then
  ok "lookup 失敗（pulls 列表）完全不動舊檔（逐位元組相同）"
else
  fail "lookup 失敗（pulls 列表）完全不動舊檔（逐位元組相同） — 檔案被動過"
fi
if [[ "$(cat "$TMP/lookup_fail4.out")" != *"候選（累計"* ]]; then
  ok "lookup 失敗（pulls 列表）不印出成功摘要（沒走到合併／寫檔那段）"
else
  fail "lookup 失敗（pulls 列表）不印出成功摘要（沒走到合併／寫檔那段） — stdout: $(cat "$TMP/lookup_fail4.out")"
fi

# 合法的空 repo：查得到 PR 列表、列表本身就是空的，是正常結果，要跟上面
# 「列表讀不到」分得清清楚楚——不能 exit 1，也不能印 LOOKUP_FAILED，兩者
# 混在一起就是本輪要修的那個缺陷本身。這條斷言存在的目的就是證明兩個案例
# 不會互相塌陷成同一種結果。
empty_out="$(bash "$MRA_DIR/scripts/build-benchmark.sh" --repo acme/empty-repo --limit 10 2>&1)"
eq "合法空 repo 結束碼 0" "0" "$?"
if [[ "$empty_out" == *"沒有 merged PR"* ]]; then
  ok "合法空 repo 印出專屬訊息"
else
  fail "合法空 repo 印出專屬訊息 — stdout: $empty_out"
fi
if [[ "$empty_out" != *"LOOKUP_FAILED"* ]]; then
  ok "合法空 repo 不印 LOOKUP_FAILED（兩者不會互相塌陷）"
else
  fail "合法空 repo 不印 LOOKUP_FAILED（兩者不會互相塌陷） — stdout: $empty_out"
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
