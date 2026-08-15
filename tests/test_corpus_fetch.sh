#!/usr/bin/env bash
# 分頁抓取與續抓 (lib/corpus-fetch.sh)。用 PATH shim 假造 gh，不打真實網路。
set -uo pipefail
MRA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export MRA_CORPUS_DIR="$TMP/cache"
# TMPDIR 指到本測試專屬的目錄。下面驗「mv 失敗不洩漏暫存檔」是用數 tmp.* 檔案做的，
# 指向共用的 TMPDIR 會數到其他行程的檔案（實測機器上有 321 個），變成間歇性紅燈。
# 這個套件會 gate 後面每一個 task，間歇性紅燈的代價遠高於這兩行。
export TMPDIR="$TMP/tmphome"
mkdir -p "$TMPDIR"

# --- 假造的 gh：依 GH_FAKE_MODE 改變行為，呼叫次數記在 GH_CALL_LOG
mkdir -p "$TMP/bin"
cat > "$TMP/bin/gh" <<'SHIM'
#!/usr/bin/env bash
echo "$*" >> "$GH_CALL_LOG"
case "$*" in
  *rate_limit*)
    # ratefail 模擬認證失敗或網路不通：gh 退出非 0 且不輸出
    if [[ "${GH_FAKE_MODE:-ok}" == "ratefail" ]]; then exit 1; fi
    printf '%s' "${GH_FAKE_RATE:-5000}"; exit 0 ;;
  *--include*)
    if [[ "${GH_FAKE_MODE:-ok}" == "nolink" ]]; then printf 'HTTP/2 200\n\n'; exit 0; fi
    # linkfail 模擬「查末頁那次 gh 呼叫本身失敗」（認證、網路），跟 nolink（HTTP
    # 200 但沒有 Link header，代表真的只有一頁）是兩種不同狀況：前者不能被當成
    # 後者蒙混過去，退出非 0 且不輸出任何東西。
    if [[ "${GH_FAKE_MODE:-ok}" == "linkfail" ]]; then exit 1; fi
    printf 'HTTP/2 200\nLink: <https://api.github.com/x?page=2>; rel="next", <https://api.github.com/x?page=%s>; rel="last"\n\n' "${GH_FAKE_LAST:-3}"
    exit 0 ;;
  *pulls/comments*)
    if [[ "${GH_FAKE_MODE:-ok}" == "fail" ]]; then exit 1; fi
    if [[ "${GH_FAKE_MODE:-ok}" == "garbage" ]]; then printf 'not json'; exit 0; fi
    printf '[{"id":1,"body":"x"}]'; exit 0 ;;
esac
exit 1
SHIM
chmod +x "$TMP/bin/gh"
export PATH="$TMP/bin:$PATH"
export GH_CALL_LOG="$TMP/calls.log"; : > "$GH_CALL_LOG"

source "$MRA_DIR/lib/corpus-fetch.sh"

errors=0; pass=0
ok()   { echo "PASS: $1"; pass=$((pass+1)); }
fail() { echo "FAIL: $1"; errors=$((errors+1)); }
eq()   { if [[ "$2" == "$3" ]]; then ok "$1"; else fail "$1 — expected [$2] got [$3]"; fi; }

eq "cache dir 可覆寫" "$TMP/cache" "$(corpus_cache_dir)"
eq "repo dir 斜線換成雙底線" "$TMP/cache/rails__rails" "$(corpus_repo_dir rails/rails)"
eq "頁碼補四位數" "$TMP/cache/rails__rails/0007.json" "$(corpus_page_file rails/rails 7)"

eq "末頁取自 Link header" "3" "$(corpus_last_page rails/rails)"
GH_FAKE_LAST=598 eq "末頁 598" "598" "$(GH_FAKE_LAST=598 corpus_last_page rails/rails)"
eq "無 Link header 視為單頁" "1" "$(GH_FAKE_MODE=nolink corpus_last_page rails/rails)"

# gh 本身失敗（linkfail）跟「沒有 Link header」（nolink）要分開處理：前者是
# 暫時性故障，不能被當成「真的只有一頁」蒙混過去——那會讓一次抓取失敗把
# 598 頁的 repo 看成 1 頁，整輪就這樣「成功」跑完。
if out="$(GH_FAKE_MODE=linkfail corpus_last_page rails/rails)"; then
  fail "gh 失敗時 corpus_last_page 應退出非 0，卻印出：$out"
else
  ok "gh 失敗時 corpus_last_page 退出非 0"
fi
eq "gh 失敗時無輸出" "" "$(GH_FAKE_MODE=linkfail corpus_last_page rails/rails 2>/dev/null)"

# 第一次抓：退出碼 0，檔案寫出
corpus_fetch_page rails/rails 1; eq "首抓退出 0" "0" "$?"
if [[ -s "$TMP/cache/rails__rails/0001.json" ]]; then ok "檔案已寫出"; else fail "檔案沒寫出"; fi

# 第二次抓同一頁：退出碼 2，且沒有新的 API 呼叫
before=$(grep -c 'pulls/comments' "$GH_CALL_LOG")
corpus_fetch_page rails/rails 1; eq "重抓退出 2（跳過）" "2" "$?"
after=$(grep -c 'pulls/comments' "$GH_CALL_LOG")
eq "跳過時不呼叫 API" "$before" "$after"

# API 失敗：退出碼 1，不留半截檔案
GH_FAKE_MODE=fail corpus_fetch_page rails/rails 2; eq "API 失敗退出 1" "1" "$?"
if [[ -e "$TMP/cache/rails__rails/0002.json" ]]; then fail "失敗時留下檔案"; else ok "失敗時不留檔"; fi

# 回傳不是 JSON 陣列：同樣視為失敗，不留檔
GH_FAKE_MODE=garbage corpus_fetch_page rails/rails 3; eq "非 JSON 退出 1" "1" "$?"
if [[ -e "$TMP/cache/rails__rails/0003.json" ]]; then fail "非 JSON 留下檔案"; else ok "非 JSON 不留檔"; fi

eq "rate remaining" "5000" "$(corpus_rate_remaining)"

# rate limit 不足時停止，並印出還剩幾頁
out="$(GH_FAKE_RATE=10 corpus_fetch_repo vuejs/vue 100)"; rc=$?
eq "rate 不足退出 3" "3" "$rc"
case "$out" in RATE_LIMIT_STOP*) ok "印出 RATE_LIMIT_STOP" ;; *) fail "缺 RATE_LIMIT_STOP：$out" ;; esac
case "$out" in *"	1	3"*) ok "印出停在第 1 頁/共 3 頁" ;; *) fail "缺頁數資訊：$out" ;; esac

# 查末頁失敗（gh --include 本身非 0）：不能沿用舊行為「當成 1 頁」再往下跑，
# 要印 LAST_PAGE_UNKNOWN 並退出 3（可重跑），完全不進抓取迴圈。用全新的 repo
# 名稱，避免跟上面已經寫過快取的 rails/rails 互相干擾。
out="$(GH_FAKE_MODE=linkfail corpus_fetch_repo octocat/no-last-page 100)"; rc=$?
eq "末頁查不到退出 3" "3" "$rc"
case "$out" in LAST_PAGE_UNKNOWN*) ok "印出 LAST_PAGE_UNKNOWN" ;; *) fail "缺 LAST_PAGE_UNKNOWN：$out" ;; esac
case "$out" in *"	octocat/no-last-page"*) ok "LAST_PAGE_UNKNOWN 帶 repo 名稱" ;; *) fail "缺 repo 名稱：$out" ;; esac
if [[ -e "$TMP/cache/octocat__no-last-page/.complete" ]]; then
  fail "末頁查不到卻寫出 .complete"
else
  ok "末頁查不到不寫 .complete"
fi

# 正常跑完三頁
out="$(corpus_fetch_repo vuejs/vue 100)"; rc=$?
eq "正常跑完退出 0" "0" "$rc"
case "$out" in DONE*fetched=3*) ok "抓了三頁" ;; *) fail "頁數不對：$out" ;; esac
eq "成功時寫出 .complete，內容是末頁頁碼" "3" "$(cat "$TMP/cache/vuejs__vue/.complete" 2>/dev/null)"

# 有頁面失敗時退出 1。沒有這條的話，把 `[[ "$failed" -eq 0 ]]` 改成無條件
# `return 0` 仍然會全綠：這是三個退出碼裡唯一沒被涵蓋的一個。
#
# 失敗時不能印 DONE：DONE 是成功形狀的一行，failed=N 只是眾多欄位之一，容易被掃過去。
# 一次實跑漏了 10 頁但 DONE 照樣印出來，驗收筆記就照著它寫成「語料完整」——這是本專案
# 存在理由的那類缺陷，出現在它自己的驗收證據上。失敗要有自己的開頭 token：FETCH_INCOMPLETE。
out="$(GH_FAKE_MODE=fail corpus_fetch_repo TanStack/query 100)"; rc=$?
eq "有頁面失敗退出 1" "1" "$rc"
case "$out" in FETCH_INCOMPLETE*) ok "印出 FETCH_INCOMPLETE" ;; *) fail "缺 FETCH_INCOMPLETE：$out" ;; esac
case "$out" in DONE*) fail "頁面失敗卻印出 DONE：$out" ;; *) ok "頁面失敗不印 DONE" ;; esac
eq "FETCH_INCOMPLETE 欄位：fetched" "0" "$(printf '%s' "$out" | cut -f3)"
eq "FETCH_INCOMPLETE 欄位：last"    "3" "$(printf '%s' "$out" | cut -f4)"
eq "FETCH_INCOMPLETE 欄位：failed"  "3" "$(printf '%s' "$out" | cut -f5)"
if [[ -e "$TMP/cache/TanStack__query/.complete" ]]; then
  fail "抓取不完整卻寫出 .complete"
else
  ok "抓取不完整不寫 .complete"
fi

# 額度查不到（不是額度用盡）要印 RATE_CHECK_FAILED，不能印成 RATE_LIMIT_STOP，
# 否則操作者會以為要等一小時，實際上是認證或網路壞了。
out="$(GH_FAKE_MODE=ratefail corpus_fetch_repo prisma/prisma 100)"; rc=$?
eq "額度查不到退出 3" "3" "$rc"
case "$out" in RATE_CHECK_FAILED*) ok "印出 RATE_CHECK_FAILED" ;; *) fail "應為 RATE_CHECK_FAILED：$out" ;; esac
if corpus_rate_remaining >/dev/null 2>&1; then ok "額度正常時 corpus_rate_remaining 回 0"; else fail "額度正常時不該失敗"; fi
eq "額度查不到時無輸出" "" "$(GH_FAKE_MODE=ratefail corpus_rate_remaining 2>/dev/null)"

# mv 失敗不得回報成功。目的地唯讀時，corpus_fetch_page 要回 1 且不留暫存檔。
ro_dir="$(corpus_repo_dir microsoft/TypeScript)"
mkdir -p "$ro_dir"; chmod 555 "$ro_dir"
# 數的是本測試專屬 TMPDIR 裡的 corpus.* 暫存檔，所以是精確計數：
# 起點必為 0，洩漏一個就是 1。數共用 TMPDIR 的 tmp.* 會數到別的行程（實測機器上
# 有 321 個）而間歇性誤報，而 corpus_fetch_page 若用 bare mktemp，在 macOS 上又會
# 因為忽略 TMPDIR 而恆為 0/0，變成永遠不會失敗的空斷言。
tmp_before="$(find "$TMPDIR" -maxdepth 1 -name 'corpus.*' 2>/dev/null | wc -l | tr -d ' ')"
eq "起點沒有殘留暫存檔" "0" "$tmp_before"
corpus_fetch_page microsoft/TypeScript 1; rc=$?
chmod 755 "$ro_dir"
eq "mv 失敗退出 1" "1" "$rc"
if [[ -e "$ro_dir/0001.json" ]]; then fail "mv 失敗卻留下檔案"; else ok "mv 失敗不留檔"; fi
tmp_after="$(find "$TMPDIR" -maxdepth 1 -name 'corpus.*' 2>/dev/null | wc -l | tr -d ' ')"
eq "mv 失敗不洩漏暫存檔" "0" "$tmp_after"

# corpus_check_complete：篩選階段合併前的完整性守門。.complete 不存在、內容壞掉、
# 或缺頁時都要擋下來；1..last 每一頁都在時才放行。
comp_repo="acme/complete-check"
comp_dir="$(corpus_repo_dir "$comp_repo")"
mkdir -p "$comp_dir"

# 沒有 .complete：沒有「應該有幾頁」的依據，expected 老實印成 ?，不假裝算得出來。
out="$(corpus_check_complete "$comp_repo")"; rc=$?
eq "沒有 .complete 時退出 1" "1" "$rc"
first_line="$(printf '%s\n' "$out" | head -1)"
eq "沒有 .complete：token" "CACHE_INCOMPLETE" "$(printf '%s' "$first_line" | cut -f1)"
eq "沒有 .complete：present=0" "0" "$(printf '%s' "$first_line" | cut -f3)"
eq "沒有 .complete：expected=?" "?" "$(printf '%s' "$first_line" | cut -f4)"

# .complete 存在但內容不是數字：跟沒有標記同一類，一樣不能假裝算得出來。
printf 'not-a-number' > "$comp_dir/.complete"
out="$(corpus_check_complete "$comp_repo")"; rc=$?
eq ".complete 內容壞掉時退出 1" "1" "$rc"
case "$out" in CACHE_INCOMPLETE*) ok ".complete 壞掉印出 CACHE_INCOMPLETE" ;; *) fail "缺 CACHE_INCOMPLETE：$out" ;; esac

# .complete 存在、末頁 3，但缺中間第 2 頁
printf '3\n' > "$comp_dir/.complete"
printf '[{"id":1}]' > "$comp_dir/0001.json"
printf '[{"id":3}]' > "$comp_dir/0003.json"
out="$(corpus_check_complete "$comp_repo")"; rc=$?
eq "缺中間頁時退出 1" "1" "$rc"
first_line="$(printf '%s\n' "$out" | head -1)"
eq "缺頁：present=2" "2" "$(printf '%s' "$first_line" | cut -f3)"
eq "缺頁：expected=3" "3" "$(printf '%s' "$first_line" | cut -f4)"
eq "缺頁：印出缺的頁碼 2" "2" "$(printf '%s\n' "$out" | tail -1)"

# 補齊第 2 頁後視為完整：退出 0，且沒有多餘輸出
printf '[{"id":2}]' > "$comp_dir/0002.json"
out="$(corpus_check_complete "$comp_repo")"; rc=$?
eq "補齊後退出 0" "0" "$rc"
eq "補齊後無輸出" "" "$out"

echo "---"; echo "Passed: $pass"; echo "Failed: $errors"
exit $((errors > 0 ? 1 : 0))
