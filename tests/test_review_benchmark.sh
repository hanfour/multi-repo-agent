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
has()  { case "$2" in *"$3"*) ok "$1" ;; *) fail "$1 — 沒看到「$3」：$2" ;; esac; }
lacks(){ case "$2" in *"$3"*) fail "$1 — 不該看到「$3」：$2" ;; *) ok "$1" ;; esac; }

# 一個沒有定義的 helper 會讓 bash 印 "command not found" 然後繼續跑，那個
# 斷言既不算 pass 也不算 fail，測試照樣印出 "Failed: 0"。實際踩過一次：三個
# 斷言靜默消失，總數看起來還變多了。這道讓未定義的指令直接算成失敗。
command_not_found_handle() {
  fail "呼叫了未定義的指令 $1（斷言被靜默跳過）"
  return 127
}

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

# --- --add 對「行號不在 PR diff 內」發警告 --------------------------------
# reviewer 讀的是 diff，diff 外的行它看不到，標了等於保證漏抓，而且事後從
# summary 完全看不出來。實測階段二的基準集 54 條裡有 10 條是這樣。
#
# 只警告不擋：標註者有可能刻意要記一個 diff 外的位置。所以斷言要驗兩件事 ——
# 有警告，而且 finding 真的被寫進去了。
OOB_BIN="$TMP/bin-oob"
mkdir -p "$OOB_BIN"
cat > "$OOB_BIN/gh" <<'SHIM'
#!/usr/bin/env bash
# 只回一個 hunk：新檔的 100 到 109 行。
#
# 外層多包一層陣列：這道檢查現在用 `gh api --paginate --slurp`（PR 可能改到
# 超過 100 個檔案，未分頁時後面的檔案在 patch 裡根本不存在，每一條標在那裡的
# finding 都會被誤報成 LINE_OUTSIDE_DIFF），而 --slurp 回的是「陣列的陣列」，
# 一頁一個元素。stub 不跟著改的話，測的是一個不存在的回應形狀。
printf '%s' '[[{"filename":"app/x.rb","patch":"@@ -100,5 +100,10 @@\n context"}]]'
SHIM
chmod +x "$OOB_BIN/gh"

OOB_DIR="$TMP/bench-oobguard"
mkdir -p "$OOB_DIR"
cat > "$OOB_DIR/candidates.json" <<'J'
[{"repo":"acme/rails-app-1","pr":9801,"merged_at":"2026-08-01T00:00:00Z","fix_commits":[],
  "confirmed":false,"expected_findings":[]}]
J

# 105 在 hunk 內（100..109），不該有警告
out_in="$(PATH="$OOB_BIN:$PATH" MRA_BENCHMARK_DIR="$OOB_DIR" \
  bash "$S" --add --repo acme/rails-app-1 9801 app/x.rb 105 HIGH "在 diff 內" 2>&1)"
lacks "行號在 diff 內時不警告" "$out_in" "LINE_OUTSIDE_DIFF"

# 500 在 hunk 外，要警告，但仍要寫進去
out_oob="$(PATH="$OOB_BIN:$PATH" MRA_BENCHMARK_DIR="$OOB_DIR" \
  bash "$S" --add --repo acme/rails-app-1 9801 app/x.rb 500 HIGH "在 diff 外" 2>&1)"
has "行號在 diff 外時發警告" "$out_oob" "LINE_OUTSIDE_DIFF"
has "警告指名是哪一個位置" "$out_oob" "app/x.rb:500"
eq "警告之後 finding 仍然被寫進去（只警告不擋）" "2" \
  "$(jq -r '.[0].expected_findings | length' "$OOB_DIR/candidates.json")"

# --- --add 對「fix commit 遠晚於 PR 合併」發警告 --------------------------
# 這個基準集是拿 fix commit 的改動範圍跟受審 PR 取交集產生的，交集算得出
# 位置，不代表那個缺陷在受審當下就存在。實測 54 條裡有 19 條屬於這種：
# 缺陷是後來某次改動才讓它成立的，reviewer 在當下看不到，標了保證漏抓。
#
# 時間差是可以程式量的訊號：無效條目的 fix commit 中位落在 PR 合併後 6.2
# 天，有效條目是 0.9 天。用 3 天當門檻，無效的 68% 會被點名，有效的只有
# 25% 會被誤報。鑑別度不完美，所以跟 LINE_OUTSIDE_DIFF 一樣只警告不擋。
GAP_DIR="$TMP/bench-gapguard"
mkdir -p "$GAP_DIR"
cat > "$GAP_DIR/candidates.json" <<'J'
[{"repo":"acme/rails-app-1","pr":9901,"merged_at":"2026-08-01T00:00:00Z",
  "fix_commits":[{"sha":"aaa111","message":"late fix","overlaps":[]}],
  "confirmed":false,"expected_findings":[]},
 {"repo":"acme/rails-app-1","pr":9902,"merged_at":"2026-08-01T00:00:00Z",
  "fix_commits":[{"sha":"bbb222","message":"same day fix","overlaps":[]}],
  "confirmed":false,"expected_findings":[]}]
J

GAP_BIN="$TMP/bin-gap"
mkdir -p "$GAP_BIN"
# gh 回一個涵蓋 105 的 hunk，讓行號那道檢查不出聲，隔離出時序這道
cat > "$GAP_BIN/gh" <<'SHIM'
#!/usr/bin/env bash
printf '%s' '[[{"filename":"app/x.rb","patch":"@@ -100,5 +100,10 @@\n context"}]]'
SHIM
chmod +x "$GAP_BIN/gh"
# git 回 fix commit 的日期：aaa111 晚 10 天，bbb222 當天
cat > "$GAP_BIN/git" <<'SHIM'
#!/usr/bin/env bash
for a in "$@"; do
  case "$a" in
    aaa111) printf '2026-08-11T00:00:00+00:00\n'; exit 0 ;;
    bbb222) printf '2026-08-01T06:00:00+00:00\n'; exit 0 ;;
  esac
done
exit 1
SHIM
chmod +x "$GAP_BIN/git"

out_late="$(PATH="$GAP_BIN:$PATH" MRA_BENCHMARK_DIR="$GAP_DIR" \
  bash "$S" --add --repo acme/rails-app-1 9901 app/x.rb 105 HIGH "晚 10 天" 2>&1)"
has "fix commit 遠晚於合併時發警告" "$out_late" "FIX_LONG_AFTER_MERGE"
has "警告帶出實際天數" "$out_late" "10"
eq "警告之後 finding 仍然被寫進去（只警告不擋）" "1" \
  "$(jq -r '.[] | select(.pr == 9901) | .expected_findings | length' "$GAP_DIR/candidates.json")"

out_same="$(PATH="$GAP_BIN:$PATH" MRA_BENCHMARK_DIR="$GAP_DIR" \
  bash "$S" --add --repo acme/rails-app-1 9902 app/x.rb 105 HIGH "當天" 2>&1)"
lacks "fix commit 就在當天時不警告" "$out_same" "FIX_LONG_AFTER_MERGE"

# gh 查不到時只是跳過這道檢查，不影響 --add
cat > "$OOB_BIN/gh" <<'SHIM'
#!/usr/bin/env bash
exit 1
SHIM
PATH="$OOB_BIN:$PATH" MRA_BENCHMARK_DIR="$OOB_DIR" \
  bash "$S" --add --repo acme/rails-app-1 9801 app/x.rb 700 HIGH "查不到 patch" >/dev/null 2>&1
rc_nogh=$?
eq "gh 查不到時 --add 仍然成功" "0" "$rc_nogh"
eq "gh 查不到時 finding 照樣寫進去" "3" \
  "$(jq -r '.[0].expected_findings | length' "$OOB_DIR/candidates.json")"

# --- blame 歸因模式的候選（build-benchmark.sh --attribution blame）---------
# 這種候選的 fix_commits[] 帶 hunks 而不是 overlaps：每個 hunk 記歸因比例
# （ratio）與 PR 當時版本的行號（head_lines）。--next 要把它們印出來讓人
# 看；--add 在填的行號附近（±15 行）沒有任何一個 hunk 的歸因達門檻時警告
# NOT_BLAMED_TO_PR。人工定案的 54 條裡，這道能點名 34 條無效裡的 20 條、
# 誤報 20 條有效裡的 3 條（notes/2026-persona-convention-coverage.md），跟
# 另外兩道一樣只警告不擋。
BL_DIR="$TMP/bench-blame"
mkdir -p "$BL_DIR"
cat > "$BL_DIR/candidates.json" <<'J'
[{"repo":"acme/rails-app-1","pr":9951,"merged_at":"2026-08-01T00:00:00Z","attribution":"blame",
  "fix_commits":[{"sha":"aaa111","message":"fix: attributed","gap_days":2.5,
    "hunks":[{"path":"app/x.rb","kind":"mod","old_from":104,"old_to":104,"new_from":104,"new_to":104,
              "n":1,"to_pr":1,"ratio":1,"head_lines":[102]},
             {"path":"app/y.rb","kind":"mod","old_from":50,"old_to":59,"new_from":50,"new_to":59,
              "n":10,"to_pr":2,"ratio":0.2,"head_lines":[51,52]}]}],
  "confirmed":null,"expected_findings":[]},
 {"repo":"acme/rails-app-1","pr":9952,"merged_at":"2026-08-01T00:00:00Z",
  "fix_commits":[{"sha":"bbb222","message":"overlap only",
    "overlaps":[{"path":"app/x.rb","pr_range":[100,110],"fix_range":[100,110]}]}],
  "confirmed":null,"expected_findings":[]}]
J

# --next 印出歸因 hunk：檔名、比例、PR 當時的行號、合併後天數
out_next="$(PATH="$GAP_BIN:$PATH" MRA_BENCHMARK_DIR="$BL_DIR" bash "$S" --next 2>&1)"
has "--next 印出歸因 hunk 的檔名" "$out_next" "app/x.rb"
has "--next 印出歸因比例" "$out_next" "1.00"
has "--next 印出 PR 當時的行號" "$out_next" "102"
has "--next 印出合併後天數" "$out_next" "2.5"

# gh 回涵蓋 100..119 的 hunk，讓 LINE_OUTSIDE_DIFF 不出聲；git stub 讓
# FIX_LONG_AFTER_MERGE 不出聲（aaa111 晚 10 天會出聲，但那是另一道，用
# lacks/has 各看自己的 token 就分得開）
cat > "$GAP_BIN/gh" <<'SHIM'
#!/usr/bin/env bash
printf '%s' '[[{"filename":"app/x.rb","patch":"@@ -100,5 +100,20 @@\n context"},{"filename":"app/y.rb","patch":"@@ -1,5 +1,200 @@\n context"}]]'
SHIM

# 行號 105，離 head_lines 102 只有 3 行、那個 hunk ratio 1.0：不警告
out_near="$(PATH="$GAP_BIN:$PATH" MRA_BENCHMARK_DIR="$BL_DIR" \
  bash "$S" --add --repo acme/rails-app-1 9951 app/x.rb 105 HIGH "靠近歸因行" 2>&1)"
lacks "填的行號靠近歸因達門檻的 hunk 時不警告" "$out_near" "NOT_BLAMED_TO_PR"

# 行號 118，離 102 有 16 行（超過 ±15）：警告，但仍寫進去
out_far="$(PATH="$GAP_BIN:$PATH" MRA_BENCHMARK_DIR="$BL_DIR" \
  bash "$S" --add --repo acme/rails-app-1 9951 app/x.rb 118 HIGH "離歸因行太遠" 2>&1)"
has "填的行號離歸因行超過 15 行時警告" "$out_far" "NOT_BLAMED_TO_PR"
has "警告指名位置" "$out_far" "app/x.rb:118"
eq "警告之後 finding 仍然被寫進去（只警告不擋）" "2" \
  "$(jq -r '.[] | select(.pr == 9951) | .expected_findings | length' "$BL_DIR/candidates.json")"

# app/y.rb 的 hunk 就在 51..52 旁邊，但 ratio 0.2 沒達門檻 0.5：警告
out_low="$(PATH="$GAP_BIN:$PATH" MRA_BENCHMARK_DIR="$BL_DIR" \
  bash "$S" --add --repo acme/rails-app-1 9951 app/y.rb 52 HIGH "比例太低" 2>&1)"
has "附近的 hunk 歸因比例未達門檻時警告" "$out_low" "NOT_BLAMED_TO_PR"
has "警告帶出附近最高的歸因比例" "$out_low" "0.2"

# 門檻可調：MRA_BACKTEST_BLAME_MIN_RATIO=0.1 時 app/y.rb:52 不再警告
out_low_ok="$(PATH="$GAP_BIN:$PATH" MRA_BENCHMARK_DIR="$BL_DIR" MRA_BACKTEST_BLAME_MIN_RATIO=0.1 \
  bash "$S" --add --repo acme/rails-app-1 9951 app/y.rb 53 HIGH "門檻調低" 2>&1)"
lacks "門檻調低到 0.1 時不警告" "$out_low_ok" "NOT_BLAMED_TO_PR"

# 檔案完全沒有任何歸因 hunk：警告
out_nofile="$(PATH="$GAP_BIN:$PATH" MRA_BENCHMARK_DIR="$BL_DIR" \
  bash "$S" --add --repo acme/rails-app-1 9951 app/z.rb 10 HIGH "沒有這個檔案的歸因" 2>&1)"
has "檔案沒有任何歸因 hunk 時警告" "$out_nofile" "NOT_BLAMED_TO_PR"

# 交集模式的候選沒有 hunks：這道檢查不適用，零行為變化
out_ov="$(PATH="$GAP_BIN:$PATH" MRA_BENCHMARK_DIR="$BL_DIR" \
  bash "$S" --add --repo acme/rails-app-1 9952 app/x.rb 500 HIGH "交集模式" 2>&1)"
lacks "交集模式的候選不做 blame 檢查" "$out_ov" "NOT_BLAMED_TO_PR"
eq "交集模式的 finding 照樣寫進去" "1" \
  "$(jq -r '.[] | select(.pr == 9952) | .expected_findings | length' "$BL_DIR/candidates.json")"

echo "---"; echo "Passed: $pass"; echo "Failed: $errors"
exit $((errors > 0 ? 1 : 0))
