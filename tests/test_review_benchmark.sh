#!/usr/bin/env bash
# 人工確認工具 (scripts/review-benchmark.sh)。
set -uo pipefail
MRA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export MRA_BENCHMARK_DIR="$TMP/bench"
mkdir -p "$MRA_BENCHMARK_DIR"

cat > "$MRA_BENCHMARK_DIR/candidates.json" <<'J'
[
 {"repo":"acme/rails-app-1","pr":4919,"merged_at":"2026-08-10T09:09:52Z",
  "fix_commits":[{"sha":"aaa111","message":"fix(y): x",
                  "overlaps":[{"path":"app/a.rb","pr_range":[92,98],"fix_range":[95,98]}]}],
  "confirmed":null,"expected_findings":[]},
 {"repo":"acme/rails-app-1","pr":4911,"merged_at":"2026-08-01T00:00:00Z",
  "fix_commits":[{"sha":"bbb222","message":"fix(z): y",
                  "overlaps":[{"path":"app/b.rb","pr_range":[10,20],"fix_range":[15,18]}]}],
  "confirmed":null,"expected_findings":[]}
]
J

errors=0; pass=0
ok()   { echo "PASS: $1"; pass=$((pass+1)); }
fail() { echo "FAIL: $1"; errors=$((errors+1)); }
eq()   { if [[ "$2" == "$3" ]]; then ok "$1"; else fail "$1 — expected [$2] got [$3]"; fi; }
S="$MRA_DIR/scripts/review-benchmark.sh"
C="$MRA_BENCHMARK_DIR/candidates.json"

eq "初始狀態" "未確認 2 / 已確認 0 / 確認為缺陷 0" "$(bash "$S" --status)"

out="$(bash "$S" --next)"
case "$out" in *4919*) ok "--next 取最舊未確認的 4919" ;; *) fail "--next 內容不對：$out" ;; esac
case "$out" in *"app/a.rb"*) ok "--next 印出重疊檔案" ;; *) fail "缺重疊檔案" ;; esac
case "$out" in *"92"*"98"*) ok "--next 印出行號區間" ;; *) fail "缺行號區間" ;; esac
case "$out" in *"github.com/acme/rails-app-1/pull/4919"*) ok "--next 印出 PR 連結" ;; *) fail "缺 PR 連結" ;; esac
case "$out" in *"github.com/acme/rails-app-1/commit/aaa111"*) ok "--next 印出 commit 連結" ;; *) fail "缺 commit 連結" ;; esac

bash "$S" --set 4919 true >/dev/null
eq "寫入 confirmed" "true" "$(jq -r '.[] | select(.pr==4919) | .confirmed' "$C")"
eq "只動指定那筆" "null" "$(jq -r '.[] | select(.pr==4911) | .confirmed' "$C")"

bash "$S" --set 4911 false >/dev/null
eq "狀態更新" "未確認 0 / 已確認 2 / 確認為缺陷 1" "$(bash "$S" --status)"

bash "$S" --add 4919 app/a.rb 95 HIGH "回傳值沒判 nil" >/dev/null
eq "追加 finding" "1" "$(jq '.[] | select(.pr==4919) | .expected_findings | length' "$C")"
eq "finding 內容" '{"line":95,"note":"回傳值沒判 nil","path":"app/a.rb","severity":"HIGH"}' \
  "$(jq -cS '.[] | select(.pr==4919) | .expected_findings[0]' "$C")"

# 同一筆候選常常不只一個當初該抓到的發現，第二次 --add 要疊加、不能把第一次
# 加的蓋掉——只呼叫一次 --add 測不出「蓋掉」跟「疊加」的差別，兩者結果一樣。
bash "$S" --add 4919 app/a.rb 96 LOW "命名不清楚" >/dev/null
eq "第二次 --add 疊加而非取代" "2" "$(jq '.[] | select(.pr==4919) | .expected_findings | length' "$C")"
eq "第一筆 finding 還在" "95" \
  "$(jq -r '.[] | select(.pr==4919) | .expected_findings[0].line' "$C")"

# --set 是可以重複下的（人工確認後可能想改判斷、或重新跑一次同樣的指令），
# 不能因為再次呼叫就把已經记下的 expected_findings 一起清空——那是在
# --set 之前用另一筆指令、花另一次人工判斷才寫進去的，兩件事互相獨立。
bash "$S" --set 4919 true >/dev/null
eq "重複 --set 不清掉已有的 expected_findings" "2" \
  "$(jq '.[] | select(.pr==4919) | .expected_findings | length' "$C")"

# 全部確認完之後 --next 要說完成，不要噴錯
out="$(bash "$S" --next)"; rc=$?
eq "全確認後退出 0" "0" "$rc"
case "$out" in *完成*|*沒有*) ok "--next 回報已無待確認" ;; *) fail "訊息不對：$out" ;; esac

# 未知 PR 要報錯
if bash "$S" --set 9999 true >/dev/null 2>&1; then fail "未知 PR 應退出非 0"; else ok "未知 PR 退出非 0"; fi

echo "---"; echo "Passed: $pass"; echo "Failed: $errors"
exit $((errors > 0 ? 1 : 0))
