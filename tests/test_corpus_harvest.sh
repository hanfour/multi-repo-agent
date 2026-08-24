#!/usr/bin/env bash
# 端到端排程 (scripts/corpus-harvest.sh)：併發設定的預設值與環境變數覆寫、
# 抓取號誌的並發上限、篩選記憶體預算的排程規則。不打真實 GitHub API，也不碰
# 使用者自己的語料快取目錄。
set -uo pipefail
MRA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export MRA_CORPUS_DIR="$TMP/cache"
# 理由同 tests/test_corpus_fetch.sh：macOS 的 bare mktemp 忽略 TMPDIR，
# 指到測試專屬的目錄才能讓下面的暫存檔計數斷言有意義。
export TMPDIR="$TMP/tmphome"
mkdir -p "$MRA_CORPUS_DIR" "$TMPDIR"

# _filter_lock 的鎖爭用重試間隔調到遠小於預設的 1 秒。門檻搜尋量出來的
# discrimination floor：預設 1 秒時要 hold >= 1.2 秒才能穩定抓到「拿掉
# 預算判斷」的 mutant（0.3 秒 0/5、1.0 秒 0/5、1.2 秒 5/5）；調到 0.05 秒後
# floor 降到 0.06～0.08 秒之間（0.06 秒只有 1-2/5，0.08 秒起穩定 5/5）。
# 下面沿用的 2 秒 hold 因此從原本只有 1.67x 的窄餘裕變成約 25x（2 / 0.08），
# 不是靠拉長 hold 硬撐出餘裕，而是讓 hold 跟造成延遲的那個常數一起變小。
export CORPUS_LOCK_RETRY_SECS=0.05

# 只 source，不執行主流程：scripts/corpus-harvest.sh 用
# `[[ "${BASH_SOURCE[0]}" == "${0}" ]]` 擋住，source 進來時兩者不相等。
source "$MRA_DIR/scripts/corpus-harvest.sh"

errors=0; pass=0
ok()   { echo "PASS: $1"; pass=$((pass+1)); }
fail() { echo "FAIL: $1"; errors=$((errors+1)); }
eq()   { if [[ "$2" == "$3" ]]; then ok "$1"; else fail "$1 — expected [$2] got [$3]"; fi; }

# --- 併發設定：預設值與環境變數覆寫 ---
eq "CORPUS_FETCH_JOBS 預設 8"       "8"    "$(_corpus_fetch_jobs)"
eq "CORPUS_FILTER_BUDGET_MB 預設 3072" "3072" "$(_corpus_filter_budget_mb)"
eq "CORPUS_FETCH_JOBS 可被環境變數覆寫"       "3"   "$(CORPUS_FETCH_JOBS=3 _corpus_fetch_jobs)"
eq "CORPUS_FILTER_BUDGET_MB 可被環境變數覆寫" "512" "$(CORPUS_FILTER_BUDGET_MB=512 _corpus_filter_budget_mb)"
eq "CORPUS_FILTER_ADMIT_TIMEOUT_SECS 預設 900"       "900" "$(_corpus_filter_admit_timeout_secs)"
eq "CORPUS_FILTER_ADMIT_TIMEOUT_SECS 可被環境變數覆寫" "5"   "$(CORPUS_FILTER_ADMIT_TIMEOUT_SECS=5 _corpus_filter_admit_timeout_secs)"
# CORPUS_LOCK_RETRY_SECS 的預設值要在子殼層裡 unset 才驗得到：這個檔案開頭
# 已經把它 export 成 0.05（見上面的說明），不 unset 的話量到的永遠是覆寫值。
eq "CORPUS_LOCK_RETRY_SECS 預設 1"       "1"    "$(unset CORPUS_LOCK_RETRY_SECS; _corpus_lock_retry_secs)"
eq "CORPUS_LOCK_RETRY_SECS 可被環境變數覆寫（本檔案開頭已覆寫成 0.05）" "0.05" "$(_corpus_lock_retry_secs)"

# --- 設定驗證：0、負數、非數字要拒絕；正整數要接受 ---
if _corpus_require_positive_int X 0 >/dev/null 2>&1; then fail "0 應被拒絕"; else ok "0 被拒絕"; fi
if _corpus_require_positive_int X -1 >/dev/null 2>&1; then fail "負數應被拒絕"; else ok "負數被拒絕"; fi
if _corpus_require_positive_int X abc >/dev/null 2>&1; then fail "非數字應被拒絕"; else ok "非數字被拒絕"; fi
if _corpus_require_positive_int X 5 >/dev/null 2>&1; then ok "正整數被接受"; else fail "正整數應被接受"; fi
case "$(_corpus_require_positive_int X 0 2>&1 >/dev/null)" in
  CORPUS_HARVEST_CONFIG_INVALID*) ok "設定不合法時印出 CORPUS_HARVEST_CONFIG_INVALID" ;;
  *) fail "缺 CORPUS_HARVEST_CONFIG_INVALID" ;;
esac

# --- 抓取號誌：FIFO token bucket 真的把同時在跑的抓取數卡在 N ---
# 5 個 worker 搶 2 個 token，每個 worker 拿到 token 後記一個 marker 檔、量一次
# 當下 marker 檔案數、睡一下再放掉。marker 計數本身沒有鎖保護「比較目前最大值」
# 那一步，但這只會讓觀測值偏低不會偏高，所以斷言「觀測到的最大值 <= N」是安全的。
_fetch_sem_init 2
active_dir="$TMP/fetch-active"
mkdir -p "$active_dir"
max_seen_file="$TMP/fetch-max-seen"
printf '0' > "$max_seen_file"

_fetch_worker() {
  local id="$1"
  _fetch_sem_acquire
  : > "$active_dir/$id"
  local n cur
  n=$(find "$active_dir" -type f | wc -l | tr -d ' ')
  cur=$(cat "$max_seen_file")
  if (( n > cur )); then printf '%s' "$n" > "$max_seen_file"; fi
  sleep 0.2
  rm -f "$active_dir/$id"
  _fetch_sem_release
}

fetch_pids=()
for i in 1 2 3 4 5; do
  _fetch_worker "$i" &
  fetch_pids+=("$!")
done
for p in "${fetch_pids[@]}"; do wait "$p"; done

max_seen="$(cat "$max_seen_file")"
if [[ "$max_seen" -le 2 ]]; then
  ok "抓取號誌把並發數卡在 2 以內（觀測到 ${max_seen}）"
else
  fail "抓取號誌沒擋住並發：觀測到 ${max_seen}，上限應是 2"
fi

# --- 抓取號誌：寫 FIFO token 失敗要回傳非 0 並印出可辨識的 token ---
#
# 用 shell function 蓋掉 printf builtin 逼寫入失敗，只蓋「寫 x 這個 token」
# 那一種呼叫，其他 printf（含錯誤訊息本身）都轉呼叫真正的 builtin——蓋成
# 無條件失敗的話，_fetch_sem_release 印錯誤訊息那次 printf 也會被打斷，
# 斷言就驗不到訊息內容。closing 這個 fd 來逼真的寫入失敗也試過，但 macOS
# 上的行為不穩定（關閉後寫入仍然「成功」），不如直接蓋 printf 可靠。
_fetch_sem_init 1
printf() { [[ "$1" == "x" ]] && return 1; command printf "$@"; }
sem_write_err="$(_fetch_sem_release 2>&1 1>/dev/null)"
sem_write_rc=$?
unset -f printf
eq "release 寫 token 失敗時退出非 0" "1" "$sem_write_rc"
case "$sem_write_err" in
  *FETCH_SEM_WRITE_FAILED*release*) ok "release 寫入失敗印出 FETCH_SEM_WRITE_FAILED" ;;
  *) fail "release 寫入失敗缺 token：$sem_write_err" ;;
esac

printf() { [[ "$1" == "x" ]] && return 1; command printf "$@"; }
sem_init_err="$(_fetch_sem_init 4 2>&1 1>/dev/null)"
sem_init_rc=$?
unset -f printf
eq "init 寫 token 失敗時退出非 0" "1" "$sem_init_rc"
case "$sem_init_err" in
  *FETCH_SEM_WRITE_FAILED*init*) ok "init 寫入失敗印出 FETCH_SEM_WRITE_FAILED" ;;
  *) fail "init 寫入失敗缺 token：$sem_init_err" ;;
esac

# --- 篩選預算排程：兩個「加起來會超預算」的重 repo 不得同時在跑 ---
#
# 用真實的背景行程 + 真實的鎖去驗，不是純算術斷言：兩個 repo 各自搶到預算後
# 把自己的權重寫進一個共用的 marker 檔、睡一段夠長的時間，再檢查「當下所有
# marker 權重總和是否超過預算」。如果排程沒有正確互斥，這個總和檢查會抓到。
_filter_inflight_write 0
BUDGET=100
budget_active_dir="$TMP/budget-active"
violation="$TMP/violation"

_budget_worker() {
  local repo="$1" weight="$2" hold="$3"
  local admit_rc
  while :; do
    _filter_try_admit "$repo" "$weight" "$BUDGET"
    admit_rc=$?
    [[ "$admit_rc" == 0 ]] && break
    if [[ "$admit_rc" == 2 ]]; then
      echo "取得排程失敗：$repo" >> "$violation"
      return
    fi
    sleep 0.05
  done
  printf '%s' "$weight" > "$budget_active_dir/$repo"
  sleep 0.05
  local total=0 f w
  for f in "$budget_active_dir"/*; do
    [[ -e "$f" ]] || continue
    w="$(cat "$f" 2>/dev/null || echo 0)"
    total=$((total + w))
  done
  if (( total > BUDGET )); then
    echo "VIOLATION: 在跑總權重 $total 超過預算 ${BUDGET}（$repo 剛加入時）" >> "$violation"
  fi
  sleep "$hold"
  rm -f "$budget_active_dir/$repo"
  _filter_release "$repo" "$weight"
}

# 連跑 3 次：跟 tests/test_build_corpus.sh 的 retention 鎖測試同一個理由，
# 只跑一次的話兩個行程未必真的疊在一起，抓不到少了鎖的版本。
budget_ok=1
for round in 1 2 3; do
  rm -rf "$budget_active_dir"; mkdir -p "$budget_active_dir"
  : > "$violation"
  # hold 給 2 秒不是隨便挑的。_filter_lock 的鎖爭用重試間隔會讓兩個幾乎
  # 同時搶鎖的 worker，其中一個單純因為鎖爭用就晚了一整個重試間隔才拿到
  # 核准——這跟排程邏輯本身有沒有 bug 完全無關，卻會把兩個 repo 在時間上
  # 錯開。重試間隔預設是 1 秒（跟 build-corpus.sh 的 _retention_lock 同一個
  # 節奏），門檻搜尋量出來的 discrimination floor 要 hold >= 1.2 秒才穩定
  # （見上面 CORPUS_LOCK_RETRY_SECS 那段）。這裡把重試間隔調到 0.05 秒，
  # floor 跟著降到 0.08 秒，2 秒 hold 因此有約 25x 餘裕，不是卡在邊緣。
  _budget_worker heavy-A 70 2 &
  bp1=$!
  _budget_worker heavy-B 70 2 &
  bp2=$!
  wait "$bp1" "$bp2"
  if [[ -s "$violation" ]]; then
    budget_ok=0
    fail "第 $round 輪：兩個重 repo（70+70>100）同時在跑時預算被超過 — $(cat "$violation")"
  fi
done
[[ "$budget_ok" == 1 ]] && ok "兩個加起來會超預算的 repo 三輪皆未同時在跑"

# --- 篩選預算排程：權重單獨就超過預算的 repo 要獨自跑 ---
#
# giant 的權重（150）比預算（100）本身還大，一定要等到完全沒有其他 repo
# 在跑（in-flight 權重歸零）才能開始；開始之後也不能讓別的 repo 插進來
# （150 已經吃滿預算，加任何正數都會超）。用兩個小 repo 在 giant 前後搶著跑，
# 驗 giant 在跑期間 marker 目錄裡真的只有它自己。
_filter_inflight_write 0
rm -rf "$budget_active_dir"; mkdir -p "$budget_active_dir"
: > "$violation"

_giant_worker() {
  local admit_rc
  while :; do
    _filter_try_admit giant 150 "$BUDGET"
    admit_rc=$?
    [[ "$admit_rc" == 0 ]] && break
    if [[ "$admit_rc" == 2 ]]; then
      echo "取得排程失敗：giant" >> "$violation"
      return
    fi
    sleep 0.05
  done
  printf 'giant' > "$budget_active_dir/giant"
  # 在整個 hold 期間每 0.1 秒都檢查一次，不是只在結尾檢查一次：small1/small2
  # 可能因為 _filter_lock 的鎖爭用重試（本檔開頭已經把 CORPUS_LOCK_RETRY_SECS
  # 調小，但仍然不是 0）比預期晚才拿到核准，牠們短暫存在的 marker 有可能
  # 只落在 hold 期間的某個中段，只在結尾看一次會錯過。
  local tick others
  for ((tick = 0; tick < 20; tick++)); do
    others=$(find "$budget_active_dir" -type f ! -name giant | wc -l | tr -d ' ')
    if (( others > 0 )); then
      echo "VIOLATION: giant 在跑時還有 $others 個其他 repo 的 marker" >> "$violation"
    fi
    sleep 0.1
  done
  rm -f "$budget_active_dir/giant"
  _filter_release giant 150
}

_small_worker() {
  local repo="$1"
  local admit_rc
  while :; do
    _filter_try_admit "$repo" 10 "$BUDGET"
    admit_rc=$?
    [[ "$admit_rc" == 0 ]] && break
    [[ "$admit_rc" == 2 ]] && return
    sleep 0.05
  done
  printf '%s' "$repo" > "$budget_active_dir/$repo"
  sleep 0.5
  rm -f "$budget_active_dir/$repo"
  _filter_release "$repo" 10
}

_giant_worker &
gp=$!
sleep 0.02
_small_worker small1 &
sp1=$!
_small_worker small2 &
sp2=$!
wait "$gp" "$sp1" "$sp2"

if [[ -s "$violation" ]]; then
  fail "giant（權重 150 > 預算 100）沒有獨自跑 — $(cat "$violation")"
else
  ok "giant（權重 150 > 預算 100）獨自跑，前後的小 repo 不會跟它重疊"
fi

# --- 排程決策要有操作者看得到的紀錄：repo、權重、in-flight 總量 ---
_filter_inflight_write 0
log_out="$(_filter_try_admit demo/repo 42 100 2>&1 >/dev/null)"
case "$log_out" in
  FILTER_SCHED_START*demo/repo*weight=42MB*inflight=42MB*budget=100MB*)
    ok "排程核准時印出 repo、權重、in-flight 總量" ;;
  *) fail "排程紀錄缺欄位：$log_out" ;;
esac
_filter_release demo/repo 42

# --- 同一個快取目錄一次只能跑一個 harvest ----------------------------------
#
# 主流程會把共用的「在跑權重總量」重置為 0。另一個 harvest 正在跑時，這個重置
# 會把它已經記入的權重整個抹掉，兩邊都以為預算是空的，於是同時放行最大的那幾
# 個 repo——而這個預算存在的唯一目的，就是不要讓好幾個 repo 的篩選峰值同時壓
# 在同一台機器上。
LOCK_CACHE="$TMP/instance-lock"
mkdir -p "$LOCK_CACHE"
if _harvest_instance_lock "$LOCK_CACHE" 2>/dev/null; then
  ok "第一個實例取得鎖"
else
  fail "第一個實例該取得鎖"
fi

# 第二次呼叫：pid 檔裡是這個還活著的行程，要被擋下來。
second_out="$(_harvest_instance_lock "$LOCK_CACHE" 2>&1)"; second_rc=$?
if [[ "$second_rc" -ne 0 ]]; then
  ok "另一個實例被擋下來"
else
  fail "另一個 harvest 正在跑時不該取得鎖"
fi
has "印出 HARVEST_ALREADY_RUNNING" "$second_out" "HARVEST_ALREADY_RUNNING"

# 殘骸接手：pid 指向一個已經結束的行程。只看「鎖目錄在不在」的實作會把上一輪
# 被 kill 掉留下的鎖當成有效，之後每次執行都被自己的殘骸擋住，而且看不出原因。
dead_pid="$(bash -c 'echo $$')"
printf '%s' "$dead_pid" > "$LOCK_CACHE/.harvest.lock/pid"
stale_out="$(_harvest_instance_lock "$LOCK_CACHE" 2>&1)"; stale_rc=$?
if [[ "$stale_rc" -eq 0 ]]; then
  ok "上一輪的殘骸鎖可以接手"
else
  fail "pid 已經不在時該接手，不是永遠被擋住：$stale_out"
fi
has "接手時印出 HARVEST_STALE_LOCK" "$stale_out" "HARVEST_STALE_LOCK"
_harvest_instance_unlock
if [[ -e "$LOCK_CACHE/.harvest.lock" ]]; then
  fail "unlock 之後鎖還在"
else
  ok "unlock 之後鎖清掉了"
fi

echo "---"; echo "Passed: $pass"; echo "Failed: $errors"
exit $((errors > 0 ? 1 : 0))
