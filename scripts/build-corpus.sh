#!/usr/bin/env bash
# 語料取材 CLI：抓取目標 repo 的 PR review comment 並套用五步篩選。
#
# 可重複執行。已抓過的頁面會跳過，所以 rate limit 中斷後直接重跑即可續抓。
set -uo pipefail

MRA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$MRA_DIR/lib/corpus-targets.sh"
source "$MRA_DIR/lib/corpus-fetch.sh"
source "$MRA_DIR/lib/corpus-filter.sh"
source "$MRA_DIR/lib/corpus-internal.sh"

ONLY_REPO=""; DO_FETCH=1; DO_FILTER=1; INTERNAL=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo)        ONLY_REPO="$2"; shift 2 ;;
    --fetch-only)  DO_FILTER=0; shift ;;
    --filter-only) DO_FETCH=0; shift ;;
    --internal)    INTERNAL=1; shift ;;
    -h|--help)
      echo "用法: build-corpus.sh [--repo <owner/name>] [--fetch-only] [--filter-only] [--internal]"
      exit 0 ;;
    *) echo "未知參數：$1" >&2; exit 1 ;;
  esac
done

RETENTION="$(corpus_cache_dir)/retention.tsv"
mkdir -p "$(corpus_cache_dir)"
# 用 -s 不用 -f：0 位元組的 retention.tsv 檔案存在但沒有表頭，-f 判斷會誤判
# 成「已經有表頭」而跳過補寫，這個檔案的第一行就會是資料列。retention.tsv 是
# Task 5 的驗收依據，第一行格式錯了下游會整份誤讀。
[[ -s "$RETENTION" ]] || printf 'repo\tn0_raw\tn1_nobot\tn2_senior\tn3_quality\tn4_prose\n' > "$RETENTION"

# 留存報告的讀改寫要互斥。--internal 讓外部與自家兩種模式共用同一份
# retention.tsv：外部語料 10 個 repo、自家語料 10 個，同時開兩個視窗各跑一種
# 是很自然的加速做法。去重是「讀全檔 → 濾掉自己那列 → 寫回」，兩個行程交錯
# 執行會丟掉對方剛寫的列，且不會有任何錯誤訊息。mkdir 在 POSIX 上是原子操作，
# 成功的那一個行程拿到鎖；macOS 預設沒有 flock 指令，所以不用 flock。
_retention_lock_mtime() {
  stat -f %m "$1" 2>/dev/null || stat -c %Y "$1" 2>/dev/null
}

_retention_lock() {
  local lock="$RETENTION.lock" waited=0 mtime age
  while ! mkdir "$lock" 2>/dev/null; do
    # 陳舊判斷一定要看「鎖目錄本身的年齡」，不能看「自己等了多久」。
    # 後者是每個行程各自的計數器而且不會重置，一旦跨過門檻，這個行程就會把它看到的
    # 任何鎖當成陳舊的砍掉 —— 包括另一個等待者前一毫秒才合法取得的新鎖。實測過：
    # 三個行程競爭時，W2 取得鎖之後 W1 立刻把它砍掉再自己取得，兩個同時進臨界區，
    # 而且沒有任何錯誤訊息。
    mtime="$(_retention_lock_mtime "$lock")"
    if [[ -n "$mtime" ]]; then
      age=$(( $(date +%s) - mtime ))
      if [[ "$age" -ge 60 ]]; then
        echo "留存報告的鎖已存在 ${age} 秒，視為陳舊並清除：$lock" >&2
        rm -rf "$lock"
        # 清完先睡一下再重試。讓贏得 mkdir 競爭的那個行程有時間建立鎖，
        # 否則同時判定陳舊的另一個行程會立刻把它的新鎖再砍掉。
        sleep 1
        continue
      fi
    fi
    sleep 1
    waited=$((waited + 1))
    if [[ "$waited" -ge 300 ]]; then
      echo "等待留存報告的鎖超過 300 秒，放棄：$lock" >&2
      return 1
    fi
  done
}
_retention_unlock() { rm -rf "$RETENTION.lock"; }
# Ctrl-C 或其他中途中斷都要放鎖，不然下一次執行會卡在 60 秒的陳舊逾時上。
trap '_retention_unlock' EXIT

if [[ -n "$ONLY_REPO" ]]; then
  if [[ "$INTERNAL" == 1 ]]; then
    # ENVIRON 而非 awk -v，理由同 lib/corpus-targets.sh 的 corpus_layer_of：
    # -v 會先處理反斜線跳脫，把 rails\/rails 收合成 rails/rails 而誤配成功，
    # 含換行的 repo 名稱還會讓 awk crash。
    layer="$(corpus_internal_targets | CORPUS_REPO="$ONLY_REPO" awk -F'\t' \
      '$1 == ENVIRON["CORPUS_REPO"] { print $2; f = 1 } END { exit !f }')" || {
      echo "不在自家目標清單中的 repo：$ONLY_REPO" >&2; exit 1; }
  elif ! layer="$(corpus_layer_of "$ONLY_REPO")"; then
    echo "不在目標清單中的 repo：$ONLY_REPO" >&2
    exit 1
  fi
  targets="$(printf '%s\t%s\n' "$ONLY_REPO" "$layer")"
elif [[ "$INTERNAL" == 1 ]]; then
  targets="$(corpus_internal_targets)"
else
  targets="$(corpus_targets)"
fi

rc=0
while IFS=$'\t' read -r repo layer; do
  [[ -z "$repo" ]] && continue

  if [[ "$DO_FETCH" == 1 ]]; then
    # 用 `if out=$(...)` 而不是 `if ! out=$(...)`：`!` 會連 $? 一起取反，
    # then 分支裡拿到的 status 永遠是 0，rate limit 的退出碼 3 就分辨不出來了。
    if out="$(corpus_fetch_repo "$repo")"; then
      echo "$out"
    else
      status=$?
      echo "$out" >&2
      if [[ "$status" == 3 ]]; then exit 3; fi
      rc=1
      continue
    fi
  fi

  if [[ "$DO_FILTER" == 1 ]]; then
    dir="$(corpus_repo_dir "$repo")"
    pages=("$dir"/[0-9]*.json)
    if [[ ! -e "${pages[0]}" ]]; then
      echo "沒有已抓取的頁面：$repo" >&2
      rc=1
      continue
    fi
    # 合併與篩選分開跑。寫成單一 pipeline 的話，jq -s 的失敗會被管線最後一個
    # 指令的退出碼蓋掉，而 corpus_filter_all 的失敗又會被重導向吃掉。
    # 給 mktemp 明確 template，理由同 lib/corpus-fetch.sh：macOS 的 bare mktemp
    # 忽略 TMPDIR，會讓任何「不洩漏暫存檔」的測試變成永遠不會失敗的空斷言。
    merged="$(mktemp "${TMPDIR:-/tmp}/corpus-merge.XXXXXX")"
    if ! jq -s 'add' "${pages[@]}" > "$merged" 2>/dev/null; then
      # 快取頁檔本身壞掉（不是合法 JSON）也算輸入無效，用同一個 FILTER_INPUT_INVALID
      # token，呼叫端不用分辨「合併失敗」跟「corpus_filter_all 自己驗出壞輸入」。
      printf 'FILTER_INPUT_INVALID\t%s\tmerge\n' "$repo" >&2
      # 舊的 filtered.json 一樣要清掉，理由跟下面篩選失敗分支一致：留著會讓
      # 這次失敗的合併看起來像是延用上一次成功的結果。
      rm -f "$merged" "$dir/filtered.json.tmp" "$dir/filtered.json"
      rc=1; continue
    fi

    err="$(mktemp "${TMPDIR:-/tmp}/corpus-err.XXXXXX")"
    # --internal 的第 2 步不是 corpus_filter_senior，改用近一年活躍留言者清單，
    # 所以要先問 gh 拿名單，再走 corpus_filter_all_internal 而不是 corpus_filter_all。
    if [[ "$INTERNAL" == 1 ]]; then
      reviewers="$(corpus_active_reviewers "$repo" 10)"
      filter_rc=0
      corpus_filter_all_internal "$repo" "$layer" "$reviewers" \
        < "$merged" > "$dir/filtered.json.tmp" 2>"$err" || filter_rc=$?
    else
      filter_rc=0
      corpus_filter_all "$repo" "$layer" \
        < "$merged" > "$dir/filtered.json.tmp" 2>"$err" || filter_rc=$?
    fi
    if [[ "$filter_rc" != 0 ]]; then
      echo "篩選失敗：$repo" >&2
      cat "$err" >&2
      # 舊的 filtered.json 要一併刪掉。留著會讓上一次成功的輸出看起來像這次的結果。
      rm -f "$merged" "$err" "$dir/filtered.json.tmp" "$dir/filtered.json"
      rc=1; continue
    fi
    mv "$dir/filtered.json.tmp" "$dir/filtered.json"
    rm -f "$merged"

    # 只有成功時才寫留存列。失敗時 stderr 是 FILTER_INPUT_INVALID 或
    # FILTER_STAGE_FAILED，直接 sed 進去會在報告裡留下一行垃圾。
    #
    # 讀改寫要互斥：--internal 讓外部與自家兩種模式共用同一份 retention.tsv，
    # 兩個行程交錯執行「讀全檔 → 濾掉自己那列 → 寫回」會丟掉對方剛寫的列，
    # 而且不會有任何錯誤訊息。取鎖之後才能動 retention.tsv。
    # 取鎖失敗（等超過 300 秒，_retention_lock 已經印過原因並回 1）算這個
    # repo 失敗，不能略過鎖直接寫，也不能假裝成功。
    if ! _retention_lock; then
      rm -f "$err"
      rc=1; continue
    fi
    # 鎖內也補一次表頭：拿到鎖之前檔案有可能被其他行程清空過。
    [[ -s "$RETENTION" ]] || printf 'repo\tn0_raw\tn1_nobot\tn2_senior\tn3_quality\tn4_prose\n' > "$RETENTION"
    # ret_tmp 每個行程要唯一，不能沿用固定路徑：兩個並行行程都寫
    # $RETENTION.tmp 的話，即使去重本身有鎖保護，也還是會互相蓋掉對方的暫存檔。
    ret_tmp="$(mktemp "${TMPDIR:-/tmp}/corpus-ret.XXXXXX")"
    # 重跑時先移除舊列，避免同一個 repo 累積多列。用 awk 的字串比對而不是
    # `grep -v "^$repo\t"`：repo 名稱會被當成正規表示式，`acme/nest-monorepo-2.0`
    # 的那個點會匹配任意字元，連 `acme/nest-monorepo-2X0` 的列一起刪掉。那個名字
    # 就在 Task 6 的自家清單裡。ENVIRON 的理由同 corpus_layer_of。
    # mv 前一定要檢查 awk 的退出碼。跟 corpus_fetch_page 的 mv 是同一個道理：
    # awk 失敗（檔案消失、I/O 錯誤）會讓 ret_tmp 是截斷或空的，不檢查
    # 直接 mv 的話，一份寫壞的暫存檔會蓋掉原本正常的 retention.tsv，且不留痕跡。
    if CORPUS_REPO="$repo" awk -F'\t' 'NR == 1 || $1 != ENVIRON["CORPUS_REPO"]' \
         "$RETENTION" > "$ret_tmp"; then
      mv "$ret_tmp" "$RETENTION"
    else
      echo "留存報告去重失敗，保留原檔：$repo" >&2
      rm -f "$ret_tmp" "$err"
      _retention_unlock
      rc=1; continue
    fi
    sed 's/^RETENTION\t//' "$err" >> "$RETENTION"
    _retention_unlock
    rm -f "$err"
  fi
done <<< "$targets"

exit "$rc"
