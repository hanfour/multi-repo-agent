#!/usr/bin/env bash
# 目標 repo 清單的結構驗證 (lib/corpus-targets.sh)。
set -uo pipefail
MRA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$MRA_DIR/lib/corpus-targets.sh"

errors=0; pass=0
ok()   { echo "PASS: $1"; pass=$((pass+1)); }
fail() { echo "FAIL: $1"; errors=$((errors+1)); }
eq()   { if [[ "$2" == "$3" ]]; then ok "$1"; else fail "$1 — expected [$2] got [$3]"; fi; }

eq "五個層" "5" "$(corpus_layers | wc -l | tr -d ' ')"

# 每行剛好兩欄
bad_cols=$(corpus_targets | awk -F'\t' 'NF != 2' | wc -l | tr -d ' ')
eq "每行兩欄" "0" "$bad_cols"

# 每個 layer 都在值域內
valid=$(corpus_layers | tr '\n' '|' | sed 's/|$//')
bad_layer=$(corpus_targets | awk -F'\t' -v v="^($valid)$" '$2 !~ v' | wc -l | tr -d ' ')
eq "layer 都在值域內" "0" "$bad_layer"

# repo 不重複
n_all=$(corpus_targets | wc -l | tr -d ' ')
n_uniq=$(corpus_targets | cut -f1 | sort -u | wc -l | tr -d ' ')
eq "repo 不重複" "$n_all" "$n_uniq"

# spec 點名的 repo 都在
for r in rails/rails microsoft/TypeScript facebook/react prisma/prisma \
         TanStack/query vuejs/core nestjs/nest vuejs/vue; do
  if corpus_targets | cut -f1 | grep -qx "$r"; then ok "含 $r"; else fail "缺 $r"; fi
done

# NestJS 語料補強：nestjs 層至少四個 repo
n_nest=$(corpus_targets | awk -F'\t' '$2=="nestjs"' | wc -l | tr -d ' ')
if [[ "$n_nest" -ge 4 ]]; then ok "nestjs 層有 $n_nest 個 repo"; else fail "nestjs 層只有 $n_nest 個，spec 要求補強"; fi

eq "查得到 rails/rails" "rails" "$(corpus_layer_of rails/rails)"
eq "查得到 facebook/react" "react" "$(corpus_layer_of facebook/react)"

if corpus_layer_of no/such-repo >/dev/null 2>&1; then
  fail "未知 repo 應退出非 0"
else
  ok "未知 repo 退出非 0"
fi
eq "未知 repo 不輸出" "" "$(corpus_layer_of no/such-repo 2>/dev/null)"

echo "---"; echo "Passed: $pass"; echo "Failed: $errors"
exit $((errors > 0 ? 1 : 0))
