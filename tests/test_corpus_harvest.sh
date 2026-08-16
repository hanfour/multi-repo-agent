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
  # hold 給 2 秒不是隨便挑的：_filter_lock 的鎖爭用重試間隔是 1 秒（跟
  # build-corpus.sh 的 _retention_lock 同一個節奏），兩個 worker 幾乎同時
  # 搶鎖時，其中一個有機會單純因為鎖爭用就晚了 1 秒才拿到核准——這跟排程
  # 邏輯本身有沒有 bug 無關。hold 太短（試過 0.3 秒）會讓這個無關的延遲
  # 剛好把兩個 repo 在時間上錯開，連拿掉預算判斷的 mutant 都測不出來。
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
  # 可能因為 _filter_lock 的鎖爭用重試（跟 build-corpus.sh 的 _retention_lock
  # 同一個 1 秒節奏）比預期晚才拿到核准，牠們短暫存在的 marker 有可能只落在
  # hold 期間的某個中段，只在結尾看一次會錯過。
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

echo "---"; echo "Passed: $pass"; echo "Failed: $errors"
exit $((errors > 0 ? 1 : 0))
