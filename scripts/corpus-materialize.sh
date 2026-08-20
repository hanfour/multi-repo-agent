#!/usr/bin/env bash
# scripts/corpus-materialize.sh — 對所有 target repo 跑落地，印進度與各層筆數。
set -uo pipefail
MRA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$MRA_DIR/lib/corpus-targets.sh"
source "$MRA_DIR/lib/corpus-filter.sh"
source "$MRA_DIR/lib/corpus-materialize.sh"

OUT="${MRA_CORPUS_MATERIALIZED:-$HOME/.cache/mra-review-corpus-materialized}"
failed=0
while IFS=$'\t' read -r repo layer; do
  [ -n "$repo" ] || continue
  printf '=== %s（%s 層）\n' "$repo" "$layer"
  if n="$(corpus_materialize_repo "$repo" "$OUT")"; then
    printf '  %s 則\n' "$n"
  else
    printf '  失敗，見上方訊息\n'
    failed=$((failed + 1))
  fi
done < <(corpus_targets)

printf '\n=== 各層筆數\n'
corpus_materialize_manifest "$OUT"
printf '\n失敗 %s 個 repo\n' "$failed"
[ "$failed" -eq 0 ] || exit 1
