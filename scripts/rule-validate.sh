#!/usr/bin/env bash
# scripts/rule-validate.sh <目錄> — 驗證目錄下所有 .md 規則檔。
set -uo pipefail
MRA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$MRA_DIR/lib/corpus-targets.sh"
source "$MRA_DIR/lib/rule-schema.sh"

DIR="${1:-}"
[ -d "$DIR" ] || { echo "用法：rule-validate.sh <規則目錄>" >&2; exit 1; }

pass=0; fail=0
for f in "$DIR"/*.md; do
  [ -e "$f" ] || continue
  if rule_validate "$f"; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
  fi
done
printf '合格 %s、不合格 %s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
