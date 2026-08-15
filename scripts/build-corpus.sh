#!/usr/bin/env bash
# 語料取材 CLI：抓取目標 repo 的 PR review comment 並套用五步篩選。
#
# 可重複執行。已抓過的頁面會跳過，所以 rate limit 中斷後直接重跑即可續抓。
set -uo pipefail

MRA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$MRA_DIR/lib/corpus-targets.sh"
source "$MRA_DIR/lib/corpus-fetch.sh"
source "$MRA_DIR/lib/corpus-filter.sh"

ONLY_REPO=""; DO_FETCH=1; DO_FILTER=1
while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo)        ONLY_REPO="$2"; shift 2 ;;
    --fetch-only)  DO_FILTER=0; shift ;;
    --filter-only) DO_FETCH=0; shift ;;
    -h|--help)
      echo "用法: build-corpus.sh [--repo <owner/name>] [--fetch-only] [--filter-only]"
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

if [[ -n "$ONLY_REPO" ]]; then
  if ! layer="$(corpus_layer_of "$ONLY_REPO")"; then
    echo "不在目標清單中的 repo：$ONLY_REPO" >&2
    exit 1
  fi
  targets="$(printf '%s\t%s\n' "$ONLY_REPO" "$layer")"
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
    if ! corpus_filter_all "$repo" "$layer" < "$merged" > "$dir/filtered.json.tmp" 2>"$err"; then
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
    # 重跑時先移除舊列，避免同一個 repo 累積多列。用 awk 的字串比對而不是
    # `grep -v "^$repo\t"`：repo 名稱會被當成正規表示式，`acme/nest-monorepo-2.0`
    # 的那個點會匹配任意字元，連 `acme/nest-monorepo-2X0` 的列一起刪掉。那個名字
    # 就在 Task 6 的自家清單裡。ENVIRON 的理由同 corpus_layer_of。
    # mv 前一定要檢查 awk 的退出碼。跟 corpus_fetch_page 的 mv 是同一個道理：
    # awk 失敗（檔案消失、I/O 錯誤）會讓 $RETENTION.tmp 是截斷或空的，不檢查
    # 直接 mv 的話，一份寫壞的暫存檔會蓋掉原本正常的 retention.tsv，且不留痕跡。
    if CORPUS_REPO="$repo" awk -F'\t' 'NR == 1 || $1 != ENVIRON["CORPUS_REPO"]' \
         "$RETENTION" > "$RETENTION.tmp"; then
      mv "$RETENTION.tmp" "$RETENTION"
    else
      echo "留存報告去重失敗，保留原檔：$repo" >&2
      rm -f "$RETENTION.tmp" "$err"
      rc=1; continue
    fi
    sed 's/^RETENTION\t//' "$err" >> "$RETENTION"
    rm -f "$err"
  fi
done <<< "$targets"

exit "$rc"
