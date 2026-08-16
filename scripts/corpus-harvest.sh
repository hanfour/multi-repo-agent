#!/usr/bin/env bash
# 用途：平行抓取 corpus_targets 所有目標 repo 的 PR review comment（僅 --fetch-only，不篩選）。用法：bash scripts/corpus-harvest.sh
#
# 為什麼只平行抓取不平行篩選：篩選會讀改寫共用的 retention.tsv，並行執行會 lost update
# （Ruling 21），而那個鎖排在 Task 6 才實作。--fetch-only 完全不碰 retention.tsv，
# 每個 repo 寫自己的快取目錄，沒有共用狀態。
#
# 併發數用 4 不是 10：GitHub 對同一 token 的併發請求有 secondary rate limit，
# 開太多會開始收到 403 而不是加速。
set -uo pipefail
MRA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export MRA_CORPUS_DIR="${MRA_CORPUS_DIR:-$HOME/.cache/mra-review-corpus}"

source "$MRA_DIR/lib/corpus-targets.sh"
source "$MRA_DIR/lib/corpus-fetch.sh"

# log 跟 repo 清單寫進 $(corpus_cache_dir)，不寫回這個腳本所在目錄：
# repo 裡不該有任何東西依賴 gitignore 掉的暫存路徑。
CACHE_DIR="$(corpus_cache_dir)"
mkdir -p "$CACHE_DIR"
LOG="$CACHE_DIR/harvest.log"
REPOS_FILE="$CACHE_DIR/repos.txt"

corpus_targets | cut -f1 > "$REPOS_FILE"

: > "$LOG"
xargs -P 4 -I{} bash -c \
  'bash "$0/scripts/build-corpus.sh" --repo "$1" --fetch-only 2>&1 | sed "s|^|[$1] |"' \
  "$MRA_DIR" {} \
  < "$REPOS_FILE" >> "$LOG" 2>&1

echo "=== 抓取結束 ===" >> "$LOG"
