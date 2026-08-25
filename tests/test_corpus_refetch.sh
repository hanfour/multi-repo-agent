#!/usr/bin/env bash
# 補抓迴圈 (scripts/corpus-refetch.sh)。
#
# 這支腳本原本把 build-corpus.sh 的退出碼整個丟掉，只留 `2>&1 | tail -1`：
# 額度用盡（退出碼 3）時它會照樣跑滿 MAX_ROUNDS 輪，實測空轉 80 次 API 呼叫，
# 最後印「達到重試上限，仍有 repo 不完整」，把一個等額度的問題誤導成資料問題。
# 而且 `| tail -1` 會把 RATE_LIMIT_STOP 那一行抹掉（它不在最後一行）。
#
# 測試用 stub 取代 build-corpus.sh，不連網路。
set -uo pipefail
MRA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

errors=0; pass=0
ok()   { echo "PASS: $1"; pass=$((pass+1)); }
fail() { echo "FAIL: $1"; errors=$((errors+1)); }
eq()   { if [[ "$2" == "$3" ]]; then ok "$1"; else fail "$1 — expected [$2] got [$3]"; fi; }
has()  { case "$2" in *"$3"*) ok "$1" ;; *) fail "$1 — 沒看到「$3」：$2" ;; esac; }
lacks(){ case "$2" in *"$3"*) fail "$1 — 不該看到「$3」：$2" ;; *) ok "$1" ;; esac; }
command_not_found_handle() { fail "呼叫了未定義的指令 $1（斷言被靜默跳過）"; return 127; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/corpus-refetch-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

S="$TMP/mra/scripts/corpus-refetch.sh"
mkdir -p "$TMP/mra/scripts" "$TMP/mra/lib"
cp "$MRA_DIR/scripts/corpus-refetch.sh" "$TMP/mra/scripts/"
cp "$MRA_DIR/lib/corpus-targets.sh" "$MRA_DIR/lib/corpus-fetch.sh" "$TMP/mra/lib/" 2>/dev/null || true

COUNTER="$TMP/calls"

# write_build_stub <mode> — 假造 build-corpus.sh。
#   ratelimit : 印出 RATE_LIMIT_STOP（不在最後一行）後 exit 3
#   fail      : 印診斷後 exit 1
#   ok        : exit 0
# heredoc 一律 quote（<<'STUB'）：不 quote 的話 stub 裡的 $(cat ...) 會在
# 「產生 stub」的當下就被執行，而不是在 stub 被呼叫時。路徑改用環境變數傳，
# 由 stub 自己在執行時讀。
write_build_stub() {
  cat > "$TMP/mra/scripts/build-corpus.sh" <<'STUB'
#!/usr/bin/env bash
echo x >> "$REFETCH_TEST_COUNTER"
mode="$(cat "$REFETCH_TEST_MODE")"
if [ "$mode" = ratelimit ]; then
  echo "RATE_LIMIT_STOP	some/repo	12	40"
  echo "抓到第 12 頁，共 40 頁"
  echo "=== 這一行是最後一行，tail -1 只會看到它"
  exit 3
elif [ "$mode" = fail ]; then
  echo "PERMANENT_FAILURE：認證失敗" >&2
  echo "=== 最後一行"
  exit 1
fi
echo "=== 完成"
exit 0
STUB
  chmod +x "$TMP/mra/scripts/build-corpus.sh"
}
export REFETCH_TEST_COUNTER="$COUNTER" REFETCH_TEST_MODE="$TMP/mode"

# 讓 _incomplete_repos 永遠回報同一個 repo（模擬「補不完」），這樣沒有早退
# 條件，測得到迴圈本身的行為。
prep_incomplete() {
  python3 - "$S" <<'PY'
import sys, pathlib
p = pathlib.Path(sys.argv[1]); t = p.read_text()
marker = "_incomplete_repos() {"
i = t.index(marker)
j = t.index("\n}", i)
t = t[:i] + "_incomplete_repos() {\n  printf '%s\\n' some/repo\n" + t[j:]
p.write_text(t)
PY
}

write_build_stub
prep_incomplete

# --- 額度用盡：立刻停，不跑滿 MAX_ROUNDS ---------------------------------
: > "$COUNTER"; echo ratelimit > "$TMP/mode"
out="$(MRA_CORPUS_REFETCH_MAX_ROUNDS=5 bash "$S" 2>&1)"
rc=$?
eq "額度用盡時退出碼是 3（不是籠統的 1）" "3" "$rc"
eq "額度用盡時只呼叫一次 build-corpus（不空轉）" "1" "$(wc -l < "$COUNTER" | tr -d ' ')"
has "訊息說明是額度問題" "$out" "額度用盡"
has "RATE_LIMIT_STOP 那一行沒有被 tail -1 抹掉" "$out" "RATE_LIMIT_STOP	some/repo"
lacks "不該誤導成資料問題" "$out" "達到重試上限"

# --- 一般失敗：印出診斷，但繼續下一輪 -------------------------------------
: > "$COUNTER"; echo fail > "$TMP/mode"
out2="$(MRA_CORPUS_REFETCH_MAX_ROUNDS=2 bash "$S" 2>&1)"
rc2=$?
has "一般失敗有自己的 token" "$out2" "REFETCH_REPO_FAILED"
has "一般失敗保留 stderr 的診斷" "$out2" "PERMANENT_FAILURE"
eq "一般失敗會跑滿設定的輪數" "2" "$(wc -l < "$COUNTER" | tr -d ' ')"
eq "跑滿仍不完整時退出碼 1" "1" "$rc2"
has "跑滿時說明是重試上限" "$out2" "達到重試上限"

echo "---"; echo "Passed: $pass"; echo "Failed: $errors"
exit $((errors > 0 ? 1 : 0))
