#!/usr/bin/env bash
# 用途：端到端平行跑完 corpus_targets 所有目標 repo 的抓取＋篩選。用法：bash scripts/corpus-harvest.sh
#
# 舊版只平行抓取（--fetch-only），篩選另外手動、逐一序列跑：篩選會讀改寫共用的
# retention.tsv，並行執行會 lost update，那個鎖排在 Task 6 才實作。Task 6 現在
# 已經完成（scripts/build-corpus.sh 的 _retention_lock／_retention_unlock），
# 篩選可以安全地並行跑了，這裡把抓取＋篩選串成同一個腳本內的端到端流程。
#
# 抓取與篩選各自有獨立的併發限制，因為瓶頸不同：
#   - 抓取受 GitHub API 對同一 token 的併發容忍度限制。實測 P4 2.19 頁/秒、
#     P8 4.82、P12 5.83，403／secondary rate limit 在三個併發度都是 0 次，
#     P8 是效益轉折點，預設併發數改成 8（CORPUS_FETCH_JOBS 可覆寫）。
#   - 篩選受本機記憶體限制。合併 JSON 越大峰值 RSS 越高，實測倍率隨大小遞減
#     （8→94MB 11.8x、66→841MB 12.7x、234→1380MB 5.9x、244→1968MB 8.1x），
#     13x 是最差觀測值，拿它當權重公式會高估大 repo，是安全的方向。這台機器
#     16GB，四個最大 repo 同時篩選估要 5.2GB，預設預算抓保守值 3072MB
#     （CORPUS_FILTER_BUDGET_MB 可覆寫）。
#
# 兩個限制不能合成同一個「job 數」關卡：如果抓取＋篩選包在同一個被併發數綁住
# 的背景工作裡，篩選跑得慢的 repo 會佔住關卡，卡住其他 repo 開始抓取，兩個
# 限制就不獨立了。所以拆成兩個各自獨立的守門機制：抓取號誌（FIFO token
# bucket）只在抓取那段時間持有；篩選預算（鎖保護的共用權重總量，手法跟
# build-corpus.sh 的 retention 鎖一致）只在篩選那段時間持有。repo 之間也不設
# 全域關卡——一個 repo 抓完就能立刻搶篩選預算，不必等其他 repo 抓完，抓取與
# 篩選才能真正重疊而不是分成「全部抓完」「全部篩完」兩個大階段。
set -uo pipefail

MRA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export MRA_CORPUS_DIR="${MRA_CORPUS_DIR:-$HOME/.cache/mra-review-corpus}"

source "$MRA_DIR/lib/corpus-targets.sh"
source "$MRA_DIR/lib/corpus-fetch.sh"

# 測試用的替身入口：測試不想真的打 GitHub API，換成一個假的 build-corpus.sh。
BUILD_CORPUS_BIN="${CORPUS_BUILD_CORPUS_BIN:-$MRA_DIR/scripts/build-corpus.sh}"

# --- 兩個併發設定，皆可用環境變數覆寫 ---
_corpus_fetch_jobs()       { printf '%s' "${CORPUS_FETCH_JOBS:-8}"; }
_corpus_filter_budget_mb() { printf '%s' "${CORPUS_FILTER_BUDGET_MB:-3072}"; }

# 併發數或記憶體預算若被設成 0、負數、或非數字，不該安靜地變成「號誌開 0 個
# token」或「預算比較永遠是 false」這種難以察覺的當掉方式，要在啟動當下就
# 用清楚的 token 擋下來。
_corpus_require_positive_int() {
  local name="$1" value="$2"
  if [[ ! "$value" =~ ^[0-9]+$ ]] || [[ "$value" -eq 0 ]]; then
    printf 'CORPUS_HARVEST_CONFIG_INVALID\t%s\t%s\n' "$name" "$value" >&2
    return 1
  fi
}

# --- 抓取號誌：FIFO token bucket，限制同時在跑的抓取數 ---
#
# 用 fd 而不是 mkdir 鎖：抓取階段每頁都要重新搶放一次，一個 598 頁的 repo
# 就是 598 次搶放，mkdir/rmdir 在這個頻率下開銷太高；FIFO 的單位元組
# read/write 是核心層級的原子操作，重複搶放很便宜。
_fetch_sem_init() {
  local n="$1" fifo
  fifo="$(mktemp -u "${TMPDIR:-/tmp}/corpus-fetch-sem.XXXXXX")"
  mkfifo "$fifo" || return 1
  exec {_FETCH_SEM_FD}<>"$fifo" || { rm -f "$fifo"; return 1; }
  rm -f "$fifo"
  local i
  for ((i = 0; i < n; i++)); do printf 'x' >&"${_FETCH_SEM_FD}"; done
}
_fetch_sem_acquire() { local _tok; read -r -n 1 -u "${_FETCH_SEM_FD}" _tok; }
_fetch_sem_release() { printf 'x' >&"${_FETCH_SEM_FD}"; }

# --- 篩選預算排程：鎖保護的共用「在跑權重總量」檔案 ---
#
# 鎖的手法跟 build-corpus.sh 的 _retention_lock 一致：mkdir 在 POSIX 上是
# 原子操作；陳舊判斷看鎖目錄本身的 mtime，不是自己等了多久，理由見那邊的
# 註解——後者是每個行程各自的計數器，一旦跨過門檻就會把別人剛拿到的合法鎖
# 也當成陳舊砍掉。這裡是獨立的檔案與鎖，不會跟 retention.tsv.lock 互相卡：
# 那把鎖保護 retention.tsv 的讀改寫，這把鎖保護排程用的權重總量，各管各的。
_filter_state_file() { printf '%s/.filter-inflight-mb' "$(corpus_cache_dir)"; }
_filter_lock_path()  { printf '%s.lock' "$(_filter_state_file)"; }

_filter_lock_mtime() { stat -f %m "$1" 2>/dev/null || stat -c %Y "$1" 2>/dev/null; }

_filter_lock() {
  local lock waited=0 mtime age
  lock="$(_filter_lock_path)"
  while ! mkdir "$lock" 2>/dev/null; do
    mtime="$(_filter_lock_mtime "$lock")"
    if [[ -n "${mtime:-}" ]]; then
      age=$(( $(date +%s) - mtime ))
      if [[ "$age" -ge 60 ]]; then
        echo "篩選排程鎖已存在 ${age} 秒，視為陳舊並清除：$lock" >&2
        rm -rf "$lock"
        sleep 1
        continue
      fi
    fi
    sleep 1
    waited=$((waited + 1))
    if [[ "$waited" -ge 300 ]]; then
      printf 'FILTER_SCHED_LOCK_TIMEOUT\t%s\n' "$lock" >&2
      return 1
    fi
  done
}
_filter_unlock() { rm -rf "$(_filter_lock_path)"; }

_filter_inflight_read() {
  local f v
  f="$(_filter_state_file)"
  v=0
  [[ -s "$f" ]] && v="$(<"$f")"
  [[ "$v" =~ ^[0-9]+$ ]] || v=0
  printf '%s' "$v"
}

# mv 的退出碼一定要檢查，理由跟 corpus-fetch.sh／build-corpus.sh 的每一個 mv
# 一樣：TMPDIR 與快取目錄常在不同檔案系統上，mv 會退化成 copy + unlink，
# 磁碟滿、配額、權限都可能讓它失敗。這裡若不檢查，寫壞的狀態檔會讓後續的
# 排程判斷全部失準，而且不留任何痕跡。
_filter_inflight_write() {
  local v="$1" f tmp
  f="$(_filter_state_file)"
  tmp="$(mktemp "${TMPDIR:-/tmp}/corpus-filter-inflight.XXXXXX")" || return 1
  if ! printf '%s' "$v" > "$tmp"; then
    rm -f "$tmp"; return 1
  fi
  if ! mv "$tmp" "$f"; then
    rm -f "$tmp"; return 1
  fi
}

# 權重 = 合併語料 MB × 13（實測最差倍率，高估大 repo 是安全的方向）。
# du -sm 讀的是快取頁檔，跟篩選階段合併用的是同一份資料，抓個大概數字就夠
# 排程用，不需要真的合併一次來量精確大小。
_corpus_weight_mb() {
  local repo="$1" dir mb
  dir="$(corpus_repo_dir "$repo")"
  mb="$(du -sm "$dir" 2>/dev/null | cut -f1)"
  [[ "$mb" =~ ^[0-9]+$ ]] || mb=0
  printf '%s' $((mb * 13))
}

# 嘗試把這個 repo 的權重計入在跑總量。
#   回傳 0：核准，已經記入在跑總量——呼叫端跑完篩選後一定要呼叫
#           _filter_release 把這筆權重扣掉。
#   回傳 1：這次沒核准，呼叫端要再等一下重試。
#   回傳 2：取鎖或寫狀態檔失敗，呼叫端要當成失敗處理，不能無限重試。
#
# 規則「單一 repo 權重就超過預算時要獨自跑」的判準是「目前在跑總量為 0」，
# 不是「這個 repo 本身還沒被核准過」——沒有這條規則，權重超過預算的 repo
# 會被一般規則卡死：它自己一個就已經超過預算，永遠等不到「加起來不超過
# 預算」的那一刻。
_filter_try_admit() {
  local repo="$1" weight="$2" budget="$3" inflight
  _filter_lock || return 2
  inflight="$(_filter_inflight_read)"

  local admit=1
  if (( weight > budget )); then
    (( inflight == 0 )) && admit=0
  elif (( inflight + weight <= budget )); then
    admit=0
  fi

  if (( admit == 0 )); then
    local new=$((inflight + weight))
    if ! _filter_inflight_write "$new"; then
      _filter_unlock
      return 2
    fi
    # 排程決策要讓操作者看得到：哪個 repo 開始了、它的權重、目前在跑總量。
    printf 'FILTER_SCHED_START\t%s\tweight=%sMB\tinflight=%sMB\tbudget=%sMB\n' \
      "$repo" "$weight" "$new" "$budget" >&2
  fi
  _filter_unlock
  return "$admit"
}

_filter_release() {
  local repo="$1" weight="$2" inflight new
  _filter_lock || { printf 'FILTER_SCHED_RELEASE_FAILED\t%s\n' "$repo" >&2; return 1; }
  inflight="$(_filter_inflight_read)"
  new=$((inflight - weight))
  (( new < 0 )) && new=0
  if ! _filter_inflight_write "$new"; then
    _filter_unlock
    printf 'FILTER_SCHED_RELEASE_FAILED\t%s\n' "$repo" >&2
    return 1
  fi
  _filter_unlock
}

# --- 單一 repo 的端到端流程：搶抓取號誌 → 抓 → 放號誌 → 搶篩選預算 → 篩 → 還預算 ---
#
# 這裡故意不呼叫 `build-corpus.sh --repo X`（不帶旗標的完整管線)，而是拆成
# --fetch-only 接 --filter-only 兩次呼叫：拆開才有地方插入「篩選前要先等
# 記憶體預算」這個關卡。兩次呼叫跟一次完整管線的最終結果等價——build-corpus.sh
# 本身不帶旗標時也就是「先做 DO_FETCH 那塊、再做 DO_FILTER 那塊」，這裡只是把
# 中間插進排程邏輯而已。抓取失敗（含 rate limit 停止）就直接回傳，不進篩選。
_harvest_repo() {
  local repo="$1" budget="$2" rc

  _fetch_sem_acquire
  bash "$BUILD_CORPUS_BIN" --repo "$repo" --fetch-only
  rc=$?
  _fetch_sem_release

  if [[ "$rc" != 0 ]]; then
    return "$rc"
  fi

  local weight admit_rc
  weight="$(_corpus_weight_mb "$repo")"
  while :; do
    _filter_try_admit "$repo" "$weight" "$budget"
    admit_rc=$?
    [[ "$admit_rc" == 0 ]] && break
    if [[ "$admit_rc" == 2 ]]; then
      return 1
    fi
    sleep 2
  done

  bash "$BUILD_CORPUS_BIN" --repo "$repo" --filter-only
  rc=$?
  _filter_release "$repo" "$weight"
  return "$rc"
}

_corpus_harvest_main() {
  local fetch_jobs budget_mb
  fetch_jobs="$(_corpus_fetch_jobs)"
  budget_mb="$(_corpus_filter_budget_mb)"
  _corpus_require_positive_int CORPUS_FETCH_JOBS "$fetch_jobs" || exit 1
  _corpus_require_positive_int CORPUS_FILTER_BUDGET_MB "$budget_mb" || exit 1

  # log 跟 repo 清單寫進 $(corpus_cache_dir)，不寫回這個腳本所在目錄：
  # repo 裡不該有任何東西依賴 gitignore 掉的暫存路徑。
  local cache_dir log repos_file
  cache_dir="$(corpus_cache_dir)"
  mkdir -p "$cache_dir"
  log="$cache_dir/harvest.log"
  repos_file="$cache_dir/repos.txt"

  corpus_targets | cut -f1 > "$repos_file"
  : > "$log"

  _fetch_sem_init "$fetch_jobs" || { echo "FETCH_SEM_INIT_FAILED" >&2; exit 1; }
  _filter_inflight_write 0 || { echo "FILTER_STATE_INIT_FAILED" >&2; exit 1; }

  # 每個 repo 一啟動就進自己的背景 subshell，不設任何全域關卡：抓取號誌與
  # 篩選預算各自獨立節流，repo 之間唯一的耦合就是這兩個共用資源。
  local pids=() repo
  while IFS= read -r repo; do
    [[ -z "$repo" ]] && continue
    ( _harvest_repo "$repo" "$budget_mb" 2>&1 | sed "s|^|[$repo] |" ) >> "$log" &
    pids+=("$!")
  done < "$repos_file"

  local rc=0 pid
  for pid in "${pids[@]}"; do
    wait "$pid" || rc=1
  done

  echo "=== 抓取結束 ===" >> "$log"
  exit "$rc"
}

# 只有直接執行這個檔案時才跑主流程；測試用 source 載入上面這些函式，改用
# 假的權重與假的 BUILD_CORPUS_BIN 單獨驗排程邏輯，不用真的打 GitHub API。
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  _corpus_harvest_main "$@"
fi
