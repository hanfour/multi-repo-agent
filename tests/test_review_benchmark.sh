#!/usr/bin/env bash
# 人工確認工具 (scripts/review-benchmark.sh)。
#
# Fix round 1：候選集的鍵是 (repo, pr)，所以 fixture 故意留一個跨 repo 撞號的
# PR 4919（acme/rails-app-1 與 acme/nest-monorepo-2.0 各一列）——這是 review 抓到的
# Critical 1 需要的最小重現案例，不用撞號就測不出「--set 動到別的 repo 那列」。
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
  "confirmed":null,"expected_findings":[]},
 {"repo":"acme/nest-monorepo-2.0","pr":4919,"merged_at":"2026-08-05T00:00:00Z",
  "fix_commits":[{"sha":"ccc333","message":"fix(w): z",
                  "overlaps":[{"path":"app/c.rb","pr_range":[1,5],"fix_range":[2,4]}]}],
  "confirmed":null,"expected_findings":[]}
]
J

errors=0; pass=0
ok()   { echo "PASS: $1"; pass=$((pass+1)); }
fail() { echo "FAIL: $1"; errors=$((errors+1)); }
eq()   { if [[ "$2" == "$3" ]]; then ok "$1"; else fail "$1 — expected [$2] got [$3]"; fi; }
S="$MRA_DIR/scripts/review-benchmark.sh"
C="$MRA_BENCHMARK_DIR/candidates.json"

# 每一條拒絕路徑都要驗兩件事：結束碼非 0、檔案完全沒被動到。存一份快照，
# 呼叫完再比對，比對相等才算過——只驗結束碼漏抓「拒絕前已經半寫入」這種錯。
snapshot() { cat "$C"; }

eq "初始狀態" "未確認 3 / 已確認 0 / 確認為缺陷 0 / 未確認已有 finding 0" "$(bash "$S" --status)"

out="$(bash "$S" --next)"
case "$out" in *4919*) ok "--next 取最舊未確認的 4919" ;; *) fail "--next 內容不對：$out" ;; esac
case "$out" in *"repo    acme/rails-app-1"*) ok "--next 印出 repo，跟 PR 並列可以直接複製回去用" ;; *) fail "缺 repo 行：$out" ;; esac
case "$out" in *"app/a.rb"*) ok "--next 印出重疊檔案" ;; *) fail "缺重疊檔案" ;; esac
case "$out" in *"92"*"98"*) ok "--next 印出行號區間" ;; *) fail "缺行號區間" ;; esac
case "$out" in *"github.com/acme/rails-app-1/pull/4919"*) ok "--next 印出 PR 連結" ;; *) fail "缺 PR 連結" ;; esac
case "$out" in *"github.com/acme/rails-app-1/commit/aaa111"*) ok "--next 印出 commit 連結" ;; *) fail "缺 commit 連結" ;; esac
case "$out" in *"--set --repo acme/rails-app-1 4919"*) ok "--next 給的指令帶 --repo，可以直接貼回去用" ;; *) fail "缺可直接貼回的 --repo 指令：$out" ;; esac

# --- Critical 1：pr 撞號時 --set／--add 不能用猜的 ---------------------------

snap="$(snapshot)"
if bash "$S" --set 4919 true >/dev/null 2>"$TMP/err1"; then
  fail "撞號 PR 不給 --repo 應該拒絕"
else
  ok "撞號 PR 不給 --repo 結束碼非 0"
fi
err="$(cat "$TMP/err1" 2>/dev/null || true)"
case "$err" in *"acme/rails-app-1"*"acme/nest-monorepo-2.0"*|*"acme/nest-monorepo-2.0"*"acme/rails-app-1"*)
  ok "撞號拒絕訊息列出兩個 repo" ;;
  *) fail "撞號拒絕訊息沒列出兩個 repo：$err" ;;
esac
eq "撞號 PR 不給 --repo 檔案沒被動" "$snap" "$(snapshot)"

snap="$(snapshot)"
if bash "$S" --add 4919 app/x.rb 1 LOW "ambiguous" >/dev/null 2>"$TMP/err2"; then
  fail "撞號 PR --add 不給 --repo 應該拒絕"
else
  ok "撞號 PR --add 不給 --repo 結束碼非 0"
fi
eq "撞號 PR --add 不給 --repo 檔案沒被動" "$snap" "$(snapshot)"

bash "$S" --set --repo acme/rails-app-1 4919 true >/dev/null
eq "帶 --repo 只動指定 repo 那列" "true" \
  "$(jq -r '.[] | select(.pr==4919 and .repo=="acme/rails-app-1") | .confirmed' "$C")"
eq "撞號的另一個 repo 那列沒被動到" "null" \
  "$(jq -r '.[] | select(.pr==4919 and .repo=="acme/nest-monorepo-2.0") | .confirmed' "$C")"
eq "沒撞號的 4911 也沒被動到" "null" "$(jq -r '.[] | select(.pr==4911) | .confirmed' "$C")"

bash "$S" --set --repo acme/nest-monorepo-2.0 4919 true >/dev/null
eq "另一個 repo 的同號 PR 可以獨立確認" "true" \
  "$(jq -r '.[] | select(.pr==4919 and .repo=="acme/nest-monorepo-2.0") | .confirmed' "$C")"

bash "$S" --add --repo acme/rails-app-1 4919 app/a.rb 95 HIGH "回傳值沒判 nil" >/dev/null
eq "帶 --repo 追加 finding 到指定的那列" "1" \
  "$(jq '.[] | select(.pr==4919 and .repo=="acme/rails-app-1") | .expected_findings | length' "$C")"
eq "finding 內容" '{"line":95,"note":"回傳值沒判 nil","path":"app/a.rb","severity":"HIGH"}' \
  "$(jq -cS '.[] | select(.pr==4919 and .repo=="acme/rails-app-1") | .expected_findings[0]' "$C")"
eq "撞號的另一個 repo 那列的 expected_findings 沒被污染" "0" \
  "$(jq '.[] | select(.pr==4919 and .repo=="acme/nest-monorepo-2.0") | .expected_findings | length' "$C")"

# 同一筆候選常常不只一個當初該抓到的發現，第二次 --add 要疊加、不能把第一次
# 加的蓋掉——只呼叫一次 --add 測不出「蓋掉」跟「疊加」的差別，兩者結果一樣。
bash "$S" --add --repo acme/rails-app-1 4919 app/a.rb 96 LOW "命名不清楚" >/dev/null
eq "第二次 --add 疊加而非取代" "2" \
  "$(jq '.[] | select(.pr==4919 and .repo=="acme/rails-app-1") | .expected_findings | length' "$C")"
eq "第一筆 finding 還在" "95" \
  "$(jq -r '.[] | select(.pr==4919 and .repo=="acme/rails-app-1") | .expected_findings[0].line' "$C")"

# --set 是可以重複下的，不能因為再次呼叫就把已經记下的 expected_findings 一起
# 清空——那是在 --set 之前用另一筆指令、花另一次人工判斷才寫進去的。同值重複
# （true → true）不算「改變決定」，不該噴警告；這裡兩件事分開驗，不然「沒有
# 清掉 findings」測得到，但「不該噴的警告有沒有誤觸」測不到。
warn="$(bash "$S" --set --repo acme/rails-app-1 4919 true 2>&1 >/dev/null)"
eq "重複下同一個值不噴警告" "" "$warn"
eq "重複 --set 不清掉已有的 expected_findings" "2" \
  "$(jq '.[] | select(.pr==4919 and .repo=="acme/rails-app-1") | .expected_findings | length' "$C")"

# --- Important 5（ALSO）：--status 要單獨算出「未確認但已有 finding」 -------
# 4911 先 --add 再 --set，製造一列「還沒確認、但已經記了 finding」的狀態，
# 確認 --status 會把它算進新增的那個數字，不是被藏起來或跟其他數字混在一起。
bash "$S" --add 4911 app/b.rb 15 MEDIUM "note1" >/dev/null
eq "未確認但已有 finding 的列會被算進新增的數字" \
  "未確認 1 / 已確認 2 / 確認為缺陷 2 / 未確認已有 finding 1" "$(bash "$S" --status)"

# --- Important 4：--set 覆蓋已確認的決定要警告、不能悄悄清掉 findings ------
warn="$(bash "$S" --set 4911 true 2>&1 >/dev/null)"
eq "第一次確認（null → true）不噴警告" "" "$warn"

warn="$(bash "$S" --set 4911 false 2>&1 >/dev/null)"
case "$warn" in *"警告"*"true"*"false"*"1"*) ok "覆蓋已確認決定會警告，帶舊值/新值/finding 數" ;;
  *) fail "警告內容不對：$warn" ;;
esac
eq "覆蓋 confirmed 不會清掉 expected_findings" "1" \
  "$(jq '.[] | select(.pr==4911) | .expected_findings | length' "$C")"

eq "全部確認完的狀態" "未確認 0 / 已確認 3 / 確認為缺陷 2 / 未確認已有 finding 0" "$(bash "$S" --status)"

# 全部確認完之後 --next 要說完成，不要噴錯
out="$(bash "$S" --next)"; rc=$?
eq "全確認後退出 0" "0" "$rc"
case "$out" in *完成*|*沒有*) ok "--next 回報已無待確認" ;; *) fail "訊息不對：$out" ;; esac

# --- Important 5：每一條拒絕路徑都要驗結束碼非 0 且檔案沒變 -----------------

snap="$(snapshot)"
if bash "$S" --set 9999 true >/dev/null 2>&1; then fail "未知 PR 應退出非 0"; else ok "未知 PR --set 退出非 0"; fi
eq "未知 PR --set 檔案沒被動" "$snap" "$(snapshot)"

snap="$(snapshot)"
if bash "$S" --add 9999 app/z.rb 1 LOW note >/dev/null 2>&1; then fail "未知 PR --add 應退出非 0"; else ok "未知 PR --add 退出非 0"; fi
eq "未知 PR --add 檔案沒被動" "$snap" "$(snapshot)"

snap="$(snapshot)"
if bash "$S" --add 4911 app/z.rb 1 BOGUS note >/dev/null 2>&1; then fail "無效 severity 應退出非 0"; else ok "無效 severity 退出非 0"; fi
eq "無效 severity 檔案沒被動" "$snap" "$(snapshot)"

snap="$(snapshot)"
if bash "$S" --set 4911 maybe >/dev/null 2>&1; then fail "無效布林值應退出非 0"; else ok "--set 無效布林值退出非 0"; fi
eq "--set 無效布林值檔案沒被動" "$snap" "$(snapshot)"

snap="$(snapshot)"
if bash "$S" --set 4911 >/dev/null 2>&1; then fail "缺參數應退出非 0"; else ok "--set 缺參數退出非 0"; fi
eq "--set 缺參數檔案沒被動" "$snap" "$(snapshot)"

snap="$(snapshot)"
if bash "$S" --add 4911 app/z.rb 1 LOW >/dev/null 2>&1; then fail "缺參數應退出非 0"; else ok "--add 缺參數退出非 0"; fi
eq "--add 缺參數檔案沒被動" "$snap" "$(snapshot)"

# --- Fix round 2：--repo 是輸入的最後一個 token、後面沒接值時不能讓 bash 自己
# 的「未綁定的變數」把使用者嚇到，要印出點名 --repo 的用法錯誤。這是上一輪
# Critical 3（找不到檔案時的診斷訊息本身炸掉）同一種「讀一個可能不存在的位置
# 參數卻沒先擋」的模式，在這一輪新寫的選項解析迴圈裡又出現一次——所以三條
# 斷言都要驗，不能只驗結束碼：bash 自己的中止也會是非 0，訊息內容才分得出
# 「工具好好地報錯」跟「工具自己炸了、剛好退出碼也是非 0」兩者的差別。

snap="$(snapshot)"
out="$(bash "$S" --set 4919 true --repo 2>&1)"; rc=$?
if [[ "$rc" -ne 0 ]]; then ok "--set 結尾缺 --repo 值退出非 0"; else fail "--set 結尾缺 --repo 值應退出非 0"; fi
case "$out" in *"--repo"*) ok "--set 結尾缺 --repo 值訊息點名 --repo" ;; *) fail "訊息沒點名 --repo：$out" ;; esac
case "$out" in *"未綁定"*|*"unbound"*) fail "--set 結尾缺 --repo 值炸出 bash 內部訊息：$out" ;;
  *) ok "--set 結尾缺 --repo 值沒有炸出 bash 內部訊息" ;;
esac
eq "--set 結尾缺 --repo 值檔案沒被動" "$snap" "$(snapshot)"

snap="$(snapshot)"
out="$(bash "$S" --add 4919 app/a.rb 95 HIGH note --repo 2>&1)"; rc=$?
if [[ "$rc" -ne 0 ]]; then ok "--add 結尾缺 --repo 值退出非 0"; else fail "--add 結尾缺 --repo 值應退出非 0"; fi
case "$out" in *"--repo"*) ok "--add 結尾缺 --repo 值訊息點名 --repo" ;; *) fail "訊息沒點名 --repo：$out" ;; esac
case "$out" in *"未綁定"*|*"unbound"*) fail "--add 結尾缺 --repo 值炸出 bash 內部訊息：$out" ;;
  *) ok "--add 結尾缺 --repo 值沒有炸出 bash 內部訊息" ;;
esac
eq "--add 結尾缺 --repo 值檔案沒被動" "$snap" "$(snapshot)"

# 截斷的 --add：只給到 path，line／severity／note 全部缺——比單缺 note 更接近
# 真實世界最可能發生的輸入方式（打到一半、複製貼上斷在中間）。
snap="$(snapshot)"
if bash "$S" --add 4919 app/a.rb >/dev/null 2>&1; then
  fail "截斷的 --add 應退出非 0"
else
  ok "截斷的 --add（缺 line/severity/note）退出非 0"
fi
eq "截斷的 --add 檔案沒被動" "$snap" "$(snapshot)"

# --- Critical 3：candidates.json 不存在時的診斷訊息本身不能炸掉 ------------
# 全形逗號緊接在 $C 後面會被 bash 的識別字詞法一起吃掉，在 zh_TW.UTF-8 語系
# 下會變成「C: 未綁定的變數」，本來要診斷問題的那行訊息本身變成新問題。
NOFILE_DIR="$TMP/nofile"; mkdir -p "$NOFILE_DIR"
out="$(MRA_BENCHMARK_DIR="$NOFILE_DIR" bash "$S" --next 2>&1)"; rc=$?
eq "找不到檔案時退出非 0" "1" "$rc"
case "$out" in *"找不到"*) ok "找不到檔案印出診斷訊息" ;; *) fail "沒印出找不到的診斷：$out" ;; esac
case "$out" in *"未綁定"*|*"unbound"*) fail "診斷訊息本身炸掉了：$out" ;; *) ok "診斷訊息沒有炸掉" ;; esac

# --- Critical 2：candidates.json 讀不動時 --next 不能謊報「確認完成」 ------
CORRUPT_DIR="$TMP/corrupt"; mkdir -p "$CORRUPT_DIR"
printf 'not valid json' > "$CORRUPT_DIR/candidates.json"
out="$(MRA_BENCHMARK_DIR="$CORRUPT_DIR" bash "$S" --next 2>&1)"; rc=$?
eq "讀取失敗退出非 0" "1" "$rc"
case "$out" in *"READ_FAILED"*) ok "讀取失敗有獨立 token" ;; *) fail "沒有獨立 token：$out" ;; esac
case "$out" in *完成*) fail "讀取失敗被誤報成確認完成：$out" ;; *) ok "讀取失敗不會被誤報成確認完成" ;; esac

echo "---"; echo "Passed: $pass"; echo "Failed: $errors"
exit $((errors > 0 ? 1 : 0))
