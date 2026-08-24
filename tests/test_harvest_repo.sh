#!/usr/bin/env bash
# _harvest_repo 的整合測試 (scripts/corpus-harvest.sh)。分兩段：段 A 用真的
# build-corpus.sh 配假的 gh PATH shim（跟 tests/test_build_corpus.sh 同一套
# 手法），驗跟真實 gh 呼叫有關的行為；段 B 用替身 build-corpus.sh
# （CORPUS_BUILD_CORPUS_BIN）驗排程／協調邏輯，不需要真的碰 gh。
set -uo pipefail
MRA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export MRA_CORPUS_DIR="$TMP/cache"
export TMPDIR="$TMP/tmphome"
mkdir -p "$MRA_CORPUS_DIR" "$TMPDIR"
# 鎖爭用重試間隔調小，理由同 tests/test_corpus_harvest.sh：避免這裡的
# hold/sleep 假設被一個跟排程邏輯無關的固定延遲拖垮。
export CORPUS_LOCK_RETRY_SECS=0.05

errors=0; pass=0
ok()   { echo "PASS: $1"; pass=$((pass+1)); }
fail() { echo "FAIL: $1"; errors=$((errors+1)); }
eq()   { if [[ "$2" == "$3" ]]; then ok "$1"; else fail "$1 — expected [$2] got [$3]"; fi; }

# =====================================================================
# 段 A：真的 build-corpus.sh + 假 gh。驗跟真實抓取行為有關的兩件事：
# rate limit 停止機制在 corpus_fetch_repo 重排後還能透過 _harvest_repo
# 正確運作；已經完整快取的 repo 透過 _harvest_repo 跑一次，完全不呼叫
# gh api rate_limit。
# =====================================================================
mkdir -p "$TMP/bin"
cat > "$TMP/bin/gh" <<'SHIM'
#!/usr/bin/env bash
echo "$*" >> "$GH_CALL_LOG"
case "$*" in
  *rate_limit*)
    printf '%s' "${GH_FAKE_RATE:-5000}"; exit 0 ;;
  *--include*)
    printf 'HTTP/2 200\nLink: <https://api.github.com/x?page=2>; rel="next", <https://api.github.com/x?page=%s>; rel="last"\n\n' "${GH_FAKE_LAST:-1}"
    exit 0 ;;
  *pulls/comments*)
    cat "$GH_FAKE_BODY"; exit 0 ;;
esac
exit 1
SHIM
chmod +x "$TMP/bin/gh"
export PATH="$TMP/bin:$PATH"
export GH_CALL_LOG="$TMP/gh-calls.log"; : > "$GH_CALL_LOG"
FIXTURE="$TMP/fixture.json"
printf '[{"id":1,"user":{"login":"dependabot[bot]"},"author_association":"NONE","body":"x","in_reply_to_id":null,"reactions":{"total_count":0},"path":"a.rb","diff_hunk":"@@ -1 +1 @@","html_url":"https://x/1","created_at":"2026-01-01T00:00:00Z"}]' > "$FIXTURE"
export GH_FAKE_BODY="$FIXTURE"

# 只 source，不執行主流程：scripts/corpus-harvest.sh 用
# `[[ "${BASH_SOURCE[0]}" == "${0}" ]]` 擋住，source 進來時兩者不相等。
# 這裡先不覆寫 CORPUS_BUILD_CORPUS_BIN，$BUILD_CORPUS_BIN 會指向真的
# scripts/build-corpus.sh。
source "$MRA_DIR/scripts/corpus-harvest.sh"
_fetch_sem_init 4
_filter_inflight_write 0

# --- 行為 1：rate limit 停止在重排後仍然透過 _harvest_repo 正確運作 ---
export GH_FAKE_LAST=3 GH_FAKE_RATE=10
err_out="$(_harvest_repo vuejs/vue 1000 2>&1 1>/dev/null)"
rc=$?
eq "rate limit 停止時 _harvest_repo 回傳 3" "3" "$rc"
case "$err_out" in
  *RATE_LIMIT_STOP*) ok "_harvest_repo 的輸出含 RATE_LIMIT_STOP" ;;
  *) fail "缺 RATE_LIMIT_STOP：$err_out" ;;
esac
case "$err_out" in
  *FILTER_SCHED_START*) fail "rate limit 停止卻仍然進了篩選排程：$err_out" ;;
  *) ok "rate limit 停止時沒有進篩選排程" ;;
esac
if [[ -e "$TMP/cache/vuejs__vue/filtered.json" ]]; then
  fail "rate limit 停止卻產出 filtered.json"
else
  ok "rate limit 停止不產出 filtered.json"
fi
unset GH_FAKE_LAST GH_FAKE_RATE

# --- 行為 2：完整快取的 repo 透過 _harvest_repo 跑一次，零 rate_limit 呼叫 ---
cached_repo="TanStack/query"
cached_dir="$TMP/cache/${cached_repo//\//__}"
mkdir -p "$cached_dir"
for p in 1 2 3; do
  printf '%s' "$(cat "$FIXTURE")" > "$cached_dir/$(printf '%04d' "$p").json"
done
printf '3\n' > "$cached_dir/.complete"
# 方向標記：手工造的快取沒跑過 fetch，少了它每一頁都會被判定成未快取
# （見 lib/corpus-fetch.sh 的 CORPUS_FETCH_DIRECTION）。
printf 'asc\n' > "$cached_dir/.sort-direction"
export GH_FAKE_LAST=3
rate_calls_before=$(grep -c 'rate_limit' "$GH_CALL_LOG")
_harvest_repo "$cached_repo" 1000 >/dev/null 2>&1
rc=$?
rate_calls_after=$(grep -c 'rate_limit' "$GH_CALL_LOG")
eq "完整快取 repo 的 _harvest_repo 退出 0" "0" "$rc"
# 只有最後一頁會重抓，所以額度查詢正好一次。
#
# 這條斷言原本要求零次，防的是「為每個已快取的頁各白付一次 rate_limit 網路
# 來回」（598 頁只缺 6 頁時就是 592 次白付）。改成 asc 排序之後，最後一頁是
# 還在長的那一頁：跳過它的話，兩次抓取之間新增、但還沒把那頁填滿的留言會永遠
# 抓不到。一次額度查詢換這個正確性是划算的，跟原本要防的量級也不同。
eq "完整快取 repo 只為最後一頁付一次 rate_limit" "1" "$((rate_calls_after - rate_calls_before))"
if [[ -s "$cached_dir/filtered.json" ]]; then
  ok "完整快取 repo 仍然跑完篩選，產出 filtered.json"
else
  fail "完整快取 repo 沒有產出 filtered.json"
fi
unset GH_FAKE_LAST

# =====================================================================
# 段 B：替身 build-corpus.sh（CORPUS_BUILD_CORPUS_BIN）。驗排程／協調邏輯，
# 不需要真的碰 gh。行為由 $STUB_CFG/<repo_key>.<mode> 設定檔控制：
# 第一欄 ok（預設）/fail/ratelimit；ok 時第二欄是 --fetch-only 要寫入的
# 填充檔大小（MB，控制 _corpus_weight_mb 算出來的權重）；第三欄是
# --filter-only 要 hold 幾秒（讓外部測試有機會觀測到它「正在跑」）。
# =====================================================================
STUB="$TMP/build-corpus-stub.sh"
cat > "$STUB" <<'SHIM'
#!/usr/bin/env bash
repo=""; mode=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo) repo="$2"; shift 2 ;;
    --fetch-only) mode="fetch"; shift ;;
    --filter-only) mode="filter"; shift ;;
    *) shift ;;
  esac
done
key="${repo//\//__}"
echo "$repo $mode" >> "$STUB_CALL_LOG"

behavior="ok"; size_mb=0; hold=0
cfg="$STUB_CFG/$key.$mode"
if [[ -f "$cfg" ]]; then
  read -r behavior size_mb hold < "$cfg"
fi

case "$behavior" in
  fail) exit 1 ;;
  ratelimit) exit 3 ;;
esac

if [[ "$mode" == "fetch" ]]; then
  mkdir -p "$MRA_CORPUS_DIR/$key"
  if [[ "${size_mb:-0}" -gt 0 ]]; then
    dd if=/dev/zero of="$MRA_CORPUS_DIR/$key/0001.json" bs=1048576 count="$size_mb" 2>/dev/null
  else
    printf '[]' > "$MRA_CORPUS_DIR/$key/0001.json"
  fi
  printf '1\n' > "$MRA_CORPUS_DIR/$key/.complete"
elif [[ "$mode" == "filter" ]]; then
  : > "$STUB_MARKER_DIR/$key"
  sleep "${hold:-0}"
  printf '[]' > "$MRA_CORPUS_DIR/$key/filtered.json"
  rm -f "$STUB_MARKER_DIR/$key"
fi
exit 0
SHIM
chmod +x "$STUB"
export CORPUS_BUILD_CORPUS_BIN="$STUB"
# corpus-harvest.sh 只在 source 當下讀一次 CORPUS_BUILD_CORPUS_BIN 來決定
# $BUILD_CORPUS_BIN，這裡已經在段 A source 過一次（那時還沒設這個環境變數），
# 所以要直接改這個變數本身才會生效；shellcheck 看不到它在另一個被 source
# 進來的檔案裡被用到，才會誤判成沒用到。
# shellcheck disable=SC2034
BUILD_CORPUS_BIN="$STUB"
STUB_CFG="$TMP/stub-cfg"; mkdir -p "$STUB_CFG"
STUB_MARKER_DIR="$TMP/stub-markers"
STUB_CALL_LOG="$TMP/stub-calls.log"
export STUB_CFG STUB_MARKER_DIR STUB_CALL_LOG

_stub_cfg() {
  local repo="$1" mode="$2" behavior="$3" size_mb="${4:-0}" hold="${5:-0}"
  printf '%s %s %s\n' "$behavior" "$size_mb" "$hold" > "$STUB_CFG/${repo//\//__}.$mode"
}

# --- 行為 3：giant 不是第一個進佇列時，「單獨超預算的 repo 要獨自跑」仍然成立 ---
#
# small1、small2 先起跑並先被核准（filter hold 0.5 秒），giant 隔了一小段
# 才開始搶預算，所以 giant 不是第一個排隊的——這跟 tests/test_corpus_harvest.sh
# 既有的排程測試（giant 先起跑）互補，驗的是同一條規則的另一個時間順序。
BUDGET3=100
: > "$STUB_CALL_LOG"; rm -rf "$STUB_MARKER_DIR"; mkdir -p "$STUB_MARKER_DIR"
_stub_cfg small1 fetch ok 1 0
_stub_cfg small1 filter ok 0 0.5
_stub_cfg small2 fetch ok 1 0
_stub_cfg small2 filter ok 0 0.5
_stub_cfg giant fetch ok 10 0    # 10MB * 13 = 130MB > 100MB 預算，單獨才能跑
_stub_cfg giant filter ok 0 0.6
_filter_inflight_write 0
violation3="$TMP/violation3"; : > "$violation3"

_b3_giant() {
  _harvest_repo giant "$BUDGET3" >/dev/null 2>&1
  local tick others
  for ((tick = 0; tick < 15; tick++)); do
    others=$(find "$STUB_MARKER_DIR" -type f ! -name giant 2>/dev/null | wc -l | tr -d ' ')
    if (( others > 0 )); then
      echo "VIOLATION: giant 在跑時還有 $others 個其他 repo 的 marker" >> "$violation3"
    fi
    sleep 0.05
  done
}

_harvest_repo small1 "$BUDGET3" >/dev/null 2>&1 &
b3p1=$!
_harvest_repo small2 "$BUDGET3" >/dev/null 2>&1 &
b3p2=$!
sleep 0.15
_b3_giant &
b3p3=$!
wait "$b3p1" "$b3p2" "$b3p3"

if [[ -s "$violation3" ]]; then
  fail "giant 不是第一個進佇列時，獨自跑的規則被違反 — $(cat "$violation3")"
else
  ok "giant 不是第一個進佇列時，仍然獨自跑（前面的小 repo 不會跟它重疊）"
fi

# --- 行為 4：兩個不同 repo 各自失敗都要浮現，整輪退出非 0 ---
:> "$STUB_CALL_LOG"
_stub_cfg fail1/x fetch fail
_stub_cfg fail2/x fetch fail
_stub_cfg ok1/x fetch ok 0 0
_stub_cfg ok1/x filter ok 0 0
_filter_inflight_write 0
corpus_targets() {
  printf 'fail1/x\tcommon\nfail2/x\tcommon\nok1/x\tcommon\n'
}
main_rc=""
( _corpus_harvest_main )
main_rc=$?
eq "兩個 repo 失敗時整輪退出非 0" "1" "$main_rc"
if grep -q '^fail1/x fetch$' "$STUB_CALL_LOG" && grep -q '^fail2/x fetch$' "$STUB_CALL_LOG"; then
  ok "兩個失敗的 repo 都真的被嘗試過（不是第一個失敗就中止）"
else
  fail "沒有兩個失敗 repo 都被嘗試過的紀錄：$(cat "$STUB_CALL_LOG")"
fi
if [[ -s "$MRA_CORPUS_DIR/ok1__x/filtered.json" ]]; then
  ok "成功的第三個 repo 不受另外兩個失敗影響，仍然產出 filtered.json"
else
  fail "成功的 repo 沒有產出 filtered.json"
fi
# 還原成真正的 corpus_targets：unset -f 會讓它整個消失，之後任何呼叫都會
# 找不到函式；重新 source 才是恢復原狀，不是隨便挑一種「清乾淨」的做法。
# shellcheck source=/dev/null
source "$MRA_DIR/lib/corpus-targets.sh"

# --- 行為 5：du -sm 只在 fetch 成功之後才會跑 ---
#
# 用 PATH shim 直接攔 du，記錄每一次呼叫的目錄參數，而不是從旁側推論——
# 這樣才是真的驗到「沒跑」而不是「看起來沒跑」。
DU_CALL_LOG="$TMP/du-calls.log"; : > "$DU_CALL_LOG"
cat > "$TMP/bin/du" <<'DUSHIM'
#!/usr/bin/env bash
echo "$*" >> "$DU_CALL_LOG"
exec /usr/bin/du "$@"
DUSHIM
chmod +x "$TMP/bin/du"
export DU_CALL_LOG

: > "$STUB_CALL_LOG"
_stub_cfg dufail/x fetch fail
_filter_inflight_write 0
_harvest_repo dufail/x 100 >/dev/null 2>&1
du_calls_after_failed_fetch=$(grep -c 'dufail__x' "$DU_CALL_LOG")
eq "fetch 失敗時 du 完全沒被呼叫" "0" "$du_calls_after_failed_fetch"

_stub_cfg duok/x fetch ok 0 0
_stub_cfg duok/x filter ok 0 0
_harvest_repo duok/x 100 >/dev/null 2>&1
rc=$?
du_calls_after_ok_fetch=$(grep -c 'duok__x' "$DU_CALL_LOG")
eq "fetch 成功時 _harvest_repo 退出 0" "0" "$rc"
if [[ "$du_calls_after_ok_fetch" -ge 1 ]]; then
  ok "fetch 成功後 du 至少被呼叫一次（用來算權重）"
else
  fail "fetch 成功卻沒有呼叫 du"
fi

# --- 行為 6（對應修正項 2）：篩選預算永遠核准不下來時，要逾時失敗而不是空等 ---
#
# 手法：先把在跑權重灌到一個永遠不會被還回去的天文數字（模擬另一個 repo 的
# 背景 subshell 在 admit 和 release 之間被砍掉），任何 repo 之後想核准都會
# 被永遠拒絕。把 admit 逾時調到 1 秒，_harvest_repo 應該在稍多於 1 秒內放棄
# 並回傳 1，而不是空等下去。
#
# 用背景行程 + 看門狗包住整段呼叫：就算逾時邏輯被改壞、迴圈真的變回無限，
# 這個測試本身也不能跟著卡死一整個 test.sh。
: > "$STUB_CALL_LOG"
_stub_cfg budgettimeout/x fetch ok 0 0
_filter_inflight_write 999999
outfile="$TMP/b6-out"; errfile="$TMP/b6-err"; rcfile="$TMP/b6-rc"
(
  CORPUS_FILTER_ADMIT_TIMEOUT_SECS=1 bash -c '
    source "'"$MRA_DIR"'/scripts/corpus-harvest.sh"
    _fetch_sem_init 4
    BUILD_CORPUS_BIN="'"$STUB"'"
    _harvest_repo budgettimeout/x 100 >"'"$outfile"'" 2>"'"$errfile"'"
    echo $? > "'"$rcfile"'"
  '
) &
hp=$!
( sleep 8; kill -9 "$hp" 2>/dev/null ) &
watchdog=$!
wait "$hp" 2>/dev/null
kill "$watchdog" 2>/dev/null
wait "$watchdog" 2>/dev/null

if [[ -s "$rcfile" ]]; then
  b6_rc="$(cat "$rcfile")"
  eq "budget 永遠不核准時 _harvest_repo 逾時後退出 1" "1" "$b6_rc"
  b6_err="$(cat "$errfile" 2>/dev/null || true)"
  case "$b6_err" in
    *FILTER_BUDGET_TIMEOUT*budgettimeout/x*) ok "逾時輸出含 FILTER_BUDGET_TIMEOUT 跟 repo 名稱" ;;
    *) fail "逾時輸出缺欄位：$b6_err" ;;
  esac
else
  fail "budget 永遠不核准時 _harvest_repo 沒有在時限內結束（逾時保護沒有生效，被看門狗砍掉）"
fi
_filter_inflight_write 0

echo "---"; echo "Passed: $pass"; echo "Failed: $errors"
exit $((errors > 0 ? 1 : 0))
exit $((errors > 0 ? 1 : 0))
