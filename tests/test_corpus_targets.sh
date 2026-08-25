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

# spec 點名的 repo 都在，而且各自在對的 layer。
# 只 grep repo 欄不夠：把 microsoft/TypeScript 標成 vue、vuejs/vue 標成 common 的 mutant
# 一樣會全過，那個測試等於沒測 layer。所以每一筆都釘死成字面值。
check_pair() {
  local repo="$1" want="$2" got
  got="$(corpus_targets | CORPUS_REPO="$repo" awk -F'\t' '$1 == ENVIRON["CORPUS_REPO"] { print $2 }')"
  eq "$repo → $want" "$want" "$got"
}
check_pair microsoft/TypeScript common
check_pair nestjs/nest          nestjs
check_pair nestjs/typeorm       nestjs
check_pair nestjs/swagger       nestjs
check_pair prisma/prisma        nestjs
check_pair rails/rails          rails
check_pair facebook/react       react
check_pair TanStack/query       react
check_pair vuejs/vue            vue
check_pair vuejs/core           vue

# 清單長度也釘住，避免有人多加一筆而沒人發現
eq "共 10 個 repo" "10" "$(corpus_targets | wc -l | tr -d ' ')"

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
