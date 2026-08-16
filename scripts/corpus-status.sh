#!/usr/bin/env bash
# 用途：查看各目標 repo 的抓取進度與 GitHub API 剩餘額度，決定續抓要跑多久。用法：bash scripts/corpus-status.sh
set -uo pipefail
MRA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$MRA_DIR/lib/corpus-targets.sh"
C="${MRA_CORPUS_DIR:-$HOME/.cache/mra-review-corpus}"

printf '%-26s %8s %8s %s\n' repo 已抓頁 filtered 狀態
total_pages=0
while IFS=$'\t' read -r repo _; do
  [ -z "$repo" ] && continue
  d="$C/${repo//\//__}"
  n=0
  [ -d "$d" ] && n=$(find "$d" -maxdepth 1 -name '[0-9]*.json' 2>/dev/null | wc -l | tr -d ' ')
  total_pages=$((total_pages + n))
  f="無"
  [ -s "$d/filtered.json" ] && f=$(jq 'length' "$d/filtered.json" 2>/dev/null || echo "壞")
  st="未開始"
  [ "$n" -gt 0 ] && st="抓取中或已完成"
  printf '%-26s %8s %8s %s\n' "$repo" "$n" "$f" "$st"
done <<< "$(corpus_targets)"

echo
echo "已抓頁數合計: $total_pages"
echo "剩餘 core 額度: $(gh api rate_limit --jq '.resources.core.remaining' 2>/dev/null)"
echo
echo "retention.tsv:"
cat "$C/retention.tsv" 2>/dev/null
