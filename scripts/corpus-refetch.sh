#!/usr/bin/env bash
# 用途：反覆補抓 corpus_targets 裡尚未寫出 .complete 的 repo，直到全部完整或達重試上限。用法：bash scripts/corpus-refetch.sh
# 缺頁是暫時性失敗（同一頁直接抓會成功），所以重試會逐步補齊。
set -uo pipefail
MRA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export MRA_CORPUS_DIR="${MRA_CORPUS_DIR:-$HOME/.cache/mra-review-corpus}"
source "$MRA_DIR/lib/corpus-targets.sh"
source "$MRA_DIR/lib/corpus-fetch.sh"
# 可覆寫：測試要用小輪數驗迴圈行為，實務上遇到大 repo 也可能要調高。
MAX_ROUNDS="${MRA_CORPUS_REFETCH_MAX_ROUNDS:-8}"

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
    # 退出碼一定要接住，而且不能只留 `| tail -1`。build-corpus.sh 用退出碼 3
    # 專門表示「額度用盡」，那種情況再跑幾輪也不會有進展 —— 實測額度用盡時
    # 這支腳本空轉了 80 次 API 呼叫，最後印的是「達到重試上限，仍有 repo
    # 不完整」，把一個等額度的問題誤導成資料問題。
    #
    # `| tail -1` 也會把 RATE_LIMIT_STOP 那一行抹掉（它不在最後一行），所以
    # 診斷改成落到暫存檔再挑重點印，不丟任何東西。
    _rf_log="$(mktemp "${TMPDIR:-/tmp}/corpus-refetch.XXXXXX")"
    bash "$MRA_DIR/scripts/build-corpus.sh" --repo "$r" --fetch-only > "$_rf_log" 2>&1
    _rf_rc=$?
    tail -1 "$_rf_log"
    if [ "$_rf_rc" -eq 3 ]; then
      echo "RATE_LIMIT_STOP：${r} 因為 GitHub API 額度用盡而停止，再跑幾輪也不會有進展。等額度重置後重跑這支腳本，已抓到的頁面會被沿用" >&2
      grep -E '^RATE_LIMIT_STOP|^RATE_CHECK_FAILED' "$_rf_log" >&2 || true
      rm -f "$_rf_log"
      exit 3
    fi
    if [ "$_rf_rc" -ne 0 ]; then
      echo "REFETCH_REPO_FAILED：${r} 補抓失敗（退出碼 ${_rf_rc}），診斷如下" >&2
      tail -20 "$_rf_log" >&2
    fi
    rm -f "$_rf_log"
  done
done

mapfile -t still_incomplete < <(_incomplete_repos)
echo "=== 達到重試上限 $MAX_ROUNDS 輪，仍有 repo 不完整"
for r in "${still_incomplete[@]}"; do
  echo "  未完整: $r"
done
exit 1
