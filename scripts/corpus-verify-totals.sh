#!/usr/bin/env bash
# 用途：獨立重算快取裡的原始總則數與頁數，不依賴 retention.tsv 或任何轉述資料。用法：bash scripts/corpus-verify-totals.sh
set -uo pipefail
C="${MRA_CORPUS_DIR:-$HOME/.cache/mra-review-corpus}"

pages=0
total=0
for d in "$C"/*/; do
  [ -f "$d/.complete" ] || continue
  n=$(find "$d" -maxdepth 1 -name '[0-9]*.json' | wc -l | tr -d ' ')
  c=$(jq -s 'add | length' "$d"/[0-9]*.json)
  pages=$((pages + n))
  total=$((total + c))
  printf '%-28s %5s 頁 %8s 則\n' "$(basename "$d")" "$n" "$c"
done
echo "---"
echo "合計 $pages 頁, $total 則"

echo
echo "篩選後合計（從 retention.tsv 的 n4 欄加總）:"
awk -F'\t' 'NR>1 {s+=$6} END {print s}' "$C/retention.tsv"
