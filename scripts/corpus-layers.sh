#!/usr/bin/env bash
# 用途：印出各層語料合計與第 1 步過濾的健全性檢查（Ruling 23）。用法：bash scripts/corpus-layers.sh
set -uo pipefail
MRA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$MRA_DIR/lib/corpus-targets.sh"
C="${MRA_CORPUS_DIR:-$HOME/.cache/mra-review-corpus}"
R="$C/retention.tsv"

echo "=== 各層合計（篩選後可用則數）==="
printf '%-10s %10s %10s %7s  %s\n' 層 原始 可用 留存率 組成
for layer in common nestjs rails react vue; do
  raw=0; use=0; parts=""
  while IFS=$'\t' read -r repo l; do
    [ "$l" != "$layer" ] && continue
    row=$(grep "^$repo	" "$R" 2>/dev/null) || continue
    r0=$(echo "$row" | cut -f2); r4=$(echo "$row" | cut -f6)
    raw=$((raw + r0)); use=$((use + r4))
    parts="$parts ${repo##*/}:$r4"
  done <<< "$(corpus_targets)"
  [ "$raw" -eq 0 ] && continue
  printf '%-10s %10s %10s %6s%%  %s\n' "$layer" "$raw" "$use" \
    "$(python3 -c "print('%.1f' % (100*$use/$raw))")" "$parts"
done

echo
echo "=== 健全性檢查：第 1 步濾掉的是誰（抽 3 個 repo）==="
for repo in prisma/prisma facebook/react rails/rails; do
  d="$C/${repo//\//__}"
  echo "--- $repo"
  jq -s -r 'add | [.[] | select((.user | type) != "object" or ((.user.login | ascii_downcase) as $u
      | ($u | test("\\[bot\\]$"))
        or (["coderabbitai","copilot","dependabot","github-actions","renovate"] | any(. == $u))))
    | (.user.login // "(帳號已刪除)")] | group_by(.) | map({u:.[0], n:length}) | sort_by(-.n) | .[0:4][]
    | "    \(.n)\t\(.u)"' "$d"/[0-9]*.json 2>/dev/null
done
