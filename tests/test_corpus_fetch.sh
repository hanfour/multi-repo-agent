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

# 正常跑完三頁
out="$(corpus_fetch_repo vuejs/vue 100)"; rc=$?
eq "正常跑完退出 0" "0" "$rc"
case "$out" in DONE*fetched=3*) ok "抓了三頁" ;; *) fail "頁數不對：$out" ;; esac

# 有頁面失敗時退出 1。沒有這條的話，把 `[[ "$failed" -eq 0 ]]` 改成無條件
# `return 0` 仍然會全綠：這是三個退出碼裡唯一沒被涵蓋的一個。
out="$(GH_FAKE_MODE=fail corpus_fetch_repo TanStack/query 100)"; rc=$?
eq "有頁面失敗退出 1" "1" "$rc"
case "$out" in DONE*failed=3*) ok "回報 failed=3" ;; *) fail "失敗數不對：$out" ;; esac

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
tmp_before="$(find "${TMPDIR:-/tmp}" -maxdepth 1 -name 'tmp.*' 2>/dev/null | wc -l | tr -d ' ')"
corpus_fetch_page microsoft/TypeScript 1; rc=$?
chmod 755 "$ro_dir"
eq "mv 失敗退出 1" "1" "$rc"
if [[ -e "$ro_dir/0001.json" ]]; then fail "mv 失敗卻留下檔案"; else ok "mv 失敗不留檔"; fi
tmp_after="$(find "${TMPDIR:-/tmp}" -maxdepth 1 -name 'tmp.*' 2>/dev/null | wc -l | tr -d ' ')"
eq "mv 失敗不洩漏暫存檔" "$tmp_before" "$tmp_after"

echo "---"; echo "Passed: $pass"; echo "Failed: $errors"
exit $((errors > 0 ? 1 : 0))
