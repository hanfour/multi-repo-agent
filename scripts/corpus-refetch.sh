#!/usr/bin/env bash
# 用途：反覆補抓 corpus_targets 裡尚未寫出 .complete 的 repo，直到全部完整或達重試上限。用法：bash scripts/corpus-refetch.sh
# 缺頁是暫時性失敗（同一頁直接抓會成功），所以重試會逐步補齊。
set -uo pipefail
MRA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export MRA_CORPUS_DIR="${MRA_CORPUS_DIR:-$HOME/.cache/mra-review-corpus}"
source "$MRA_DIR/lib/corpus-targets.sh"
source "$MRA_DIR/lib/corpus-fetch.sh"
MAX_ROUNDS=8

# 列出 corpus_targets 裡還沒寫出 .complete 標記的 repo，一行一個。
_incomplete_repos() {
  local repo dir
  while IFS=$'\t' read -r repo _; do
    [[ -z "$repo" ]] && continue
    dir="$(corpus_repo_dir "$repo")"
    [[ -f "$dir/.complete" ]] && continue
    printf '%s\n' "$repo"
  done <<< "$(corpus_targets)"
}

for round in $(seq 1 "$MAX_ROUNDS"); do
  mapfile -t remaining < <(_incomplete_repos)
  if [[ "${#remaining[@]}" -eq 0 ]]; then
    if [[ "$round" -eq 1 ]]; then
      echo "=== 全部已完整，無需補抓"
    else
      echo "=== 全部補齊，第 $round 輪結束"
    fi
    exit 0
  fi
  for r in "${remaining[@]}"; do
    echo "--- round $round: $r"
    bash "$MRA_DIR/scripts/build-corpus.sh" --repo "$r" --fetch-only 2>&1 | tail -1
  done
done

mapfile -t still_incomplete < <(_incomplete_repos)
echo "=== 達到重試上限 $MAX_ROUNDS 輪，仍有 repo 不完整"
for r in "${still_incomplete[@]}"; do
  echo "  未完整: $r"
done
exit 1
