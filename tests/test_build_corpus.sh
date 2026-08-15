#!/usr/bin/env bash
# CLI 進入點 (scripts/build-corpus.sh)。用 PATH shim 假造 gh。
set -uo pipefail
MRA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export MRA_CORPUS_DIR="$TMP/cache"

mkdir -p "$TMP/bin"
cat > "$TMP/bin/gh" <<'SHIM'
#!/usr/bin/env bash
case "$*" in
  *rate_limit*) printf '%s' "${GH_FAKE_RATE:-5000}"; exit 0 ;;
  *--include*)  printf 'HTTP/2 200\nLink: <https://x?page=2>; rel="next", <https://x?page=1>; rel="last"\n\n'; exit 0 ;;
esac
# corpus_active_reviewers (--internal) calls `gh api ... --jq EXPR`. Apply the
# expression with real jq against the fixture, same as real gh would.
args=("$@")
for ((i = 0; i < ${#args[@]}; i++)); do
  if [[ "${args[$i]}" == "--jq" && "$*" == *pulls/comments* ]]; then
    jq -r "${args[$((i + 1))]}" "$GH_FAKE_BODY"
    exit 0
  fi
done
case "$*" in
  *pulls/comments*) cat "$GH_FAKE_BODY"; exit 0 ;;
esac
exit 1
SHIM
chmod +x "$TMP/bin/gh"
export PATH="$TMP/bin:$PATH"
export GH_FAKE_BODY="$MRA_DIR/tests/fixtures/corpus/sample-comments.json"

errors=0; pass=0
ok()   { echo "PASS: $1"; pass=$((pass+1)); }
fail() { echo "FAIL: $1"; errors=$((errors+1)); }
eq()   { if [[ "$2" == "$3" ]]; then ok "$1"; else fail "$1 — expected [$2] got [$3]"; fi; }

# 單一 repo：抓 + 篩
bash "$MRA_DIR/scripts/build-corpus.sh" --repo rails/rails >/dev/null 2>&1
eq "退出碼 0" "0" "$?"

f="$TMP/cache/rails__rails/filtered.json"
if [[ -s "$f" ]]; then ok "filtered.json 產出"; else fail "filtered.json 沒產出"; fi
eq "篩選後 4 筆" "4" "$(jq 'length' "$f")"
eq "帶 layer"    "rails" "$(jq -r '.[0].layer' "$f")"

r="$TMP/cache/retention.tsv"
if [[ -s "$r" ]]; then ok "retention.tsv 產出"; else fail "retention.tsv 沒產出"; fi
eq "留存數那行" "rails/rails	10	7	6	5	4" "$(grep '^rails/rails' "$r")"

# 重跑：不重複追加同一個 repo 的留存列
bash "$MRA_DIR/scripts/build-corpus.sh" --repo rails/rails >/dev/null 2>&1
eq "重跑後仍只有一列" "1" "$(grep -c '^rails/rails' "$r")"

# 去重只能動自己那一列。塞兩列不相干的資料進去，跑一次 CLI，它們必須都還在。
# 注意這裡是透過 CLI 驗，不是在測試檔裡把 awk 重打一遍 —— 那樣測的是測試自己
# 寫的運算式，把腳本裡的去重改壞也不會紅。
printf 'zz/decoy-one\t1\t1\t1\t1\t1\nzz/decoy-two\t9\t9\t9\t9\t9\n' >> "$r"
bash "$MRA_DIR/scripts/build-corpus.sh" --repo rails/rails >/dev/null 2>&1
eq "rails/rails 仍只有一列" "1" "$(grep -c '^rails/rails	' "$r")"
eq "不相干的列一：還在" "1" "$(grep -c '^zz/decoy-one	' "$r")"
eq "不相干的列二：還在" "1" "$(grep -c '^zz/decoy-two	' "$r")"
eq "表頭還在且只有一行" "1" "$(grep -c '^repo	' "$r")"

# retention.tsv 是 0 位元組時要補回表頭。用 -f 判斷的話檔案存在就跳過補表頭，
# 產出的第一行會是資料列，而這個檔案是階段一的驗收依據。
: > "$r"
bash "$MRA_DIR/scripts/build-corpus.sh" --repo rails/rails >/dev/null 2>&1
eq "空檔會補回表頭" "repo" "$(head -1 "$r" | cut -f1)"
eq "補表頭後資料列還在" "1" "$(grep -c '^rails/rails	' "$r")"

# repo 名稱含正規表示式 metachar 的回歸測試不在這裡：Task 4 的目標清單裡沒有
# 任何含 metachar 的名稱，這條路徑在本 task 的 CLI 上觸發不到。真正會踩到的是
# Task 6 的 acme/nest-monorepo-2.0，測試放在那邊（見 Task 6 的對應區塊）。
#
# awk 裡的 `NR == 1` 也測不到，這是預期的不是缺口：表頭第一欄是字面值 "repo"，
# 而 --repo 的值一定是 owner/name 帶斜線，兩者永遠不相等，所以拿掉 NR == 1
# 表頭仍然會留著。那一項是防禦性的，留著但不必為它設計測試。

# 未知 repo：拒絕並退出非 0
if bash "$MRA_DIR/scripts/build-corpus.sh" --repo no/such-repo >/dev/null 2>&1; then
  fail "未知 repo 應退出非 0"
else
  ok "未知 repo 退出非 0"
fi

# rate limit 不足：退出 3，且訊息說得出還剩幾頁
out="$(GH_FAKE_RATE=5 bash "$MRA_DIR/scripts/build-corpus.sh" --repo vuejs/vue 2>&1)"; rc=$?
eq "rate 不足退出 3" "3" "$rc"
case "$out" in *RATE_LIMIT_STOP*) ok "訊息含 RATE_LIMIT_STOP" ;; *) fail "缺 RATE_LIMIT_STOP：$out" ;; esac

# 篩選失敗必須傳到退出碼，而且不能污染 retention.tsv、也不能留下看似成功的舊輸出。
# corpus_filter_all 已經會在壞輸入時退出 1，這裡驗 CLI 有沒有接住。
bad_dir="$TMP/cache/TanStack__query"
mkdir -p "$bad_dir"
# .complete 要先補上：這個 fixture 是手工造的、從沒真的跑過 fetch，Fix 1(c) 的
# 完整性檢查會在合併之前擋下沒有 .complete 的快取，這裡要測的是「合併階段本身」
# 壞掉（FILTER_INPUT_INVALID），不是完整性檢查那一層，兩層各自有各自的測試。
printf '1\n' > "$bad_dir/.complete"
printf '{not valid json' > "$bad_dir/0001.json"
lines_before="$(wc -l < "$TMP/cache/retention.tsv" | tr -d ' ')"
out="$(bash "$MRA_DIR/scripts/build-corpus.sh" --repo TanStack/query --filter-only 2>&1)"; rc=$?
eq "篩選失敗退出 1" "1" "$rc"
case "$out" in *FILTER_INPUT_INVALID*) ok "訊息含 FILTER_INPUT_INVALID" ;; *) fail "缺 FILTER_INPUT_INVALID：$out" ;; esac
eq "失敗不寫留存列" "$lines_before" "$(wc -l < "$TMP/cache/retention.tsv" | tr -d ' ')"
if [[ -e "$bad_dir/filtered.json" ]]; then fail "篩選失敗卻留下 filtered.json"; else ok "篩選失敗不留 filtered.json"; fi
if [[ -e "$bad_dir/filtered.json.tmp" ]]; then fail "留下暫存的 filtered.json.tmp"; else ok "不留 filtered.json.tmp"; fi

# 先成功再失敗：舊的 filtered.json 不得留著假裝是這次的結果
printf '%s' "$(cat "$GH_FAKE_BODY")" > "$bad_dir/0001.json"
bash "$MRA_DIR/scripts/build-corpus.sh" --repo TanStack/query --filter-only >/dev/null 2>&1
if [[ -s "$bad_dir/filtered.json" ]]; then ok "成功時有產出 filtered.json"; else fail "成功時沒產出"; fi
printf '{not valid json' > "$bad_dir/0001.json"
bash "$MRA_DIR/scripts/build-corpus.sh" --repo TanStack/query --filter-only >/dev/null 2>&1
if [[ -e "$bad_dir/filtered.json" ]]; then fail "失敗後舊的 filtered.json 還在"; else ok "失敗後移除舊的 filtered.json"; fi

# Fix 1(c)：篩選前的快取完整性檢查要蓋過原本「有沒有任何頁檔」那層判斷——有頁檔
# 不代表頁碼是連續的。沒有 .complete（從沒真的抓完過）時要擋下來，不寫留存列、
# 不寫 filtered.json。
rm -f "$bad_dir/.complete"
printf '%s' "$(cat "$GH_FAKE_BODY")" > "$bad_dir/0001.json"
lines_before="$(wc -l < "$r" | tr -d ' ')"
out="$(bash "$MRA_DIR/scripts/build-corpus.sh" --repo TanStack/query --filter-only 2>&1)"; rc=$?
if [[ "$rc" != 0 ]]; then ok "沒有 .complete 時退出非 0"; else fail "沒有 .complete 卻退出 0"; fi
case "$out" in *CACHE_INCOMPLETE*) ok "沒有 .complete 訊息含 CACHE_INCOMPLETE" ;; *) fail "缺 CACHE_INCOMPLETE：$out" ;; esac
eq "沒有 .complete 不寫留存列" "$lines_before" "$(wc -l < "$r" | tr -d ' ')"
if [[ -e "$bad_dir/filtered.json" ]]; then fail "沒有 .complete 卻留下 filtered.json"; else ok "沒有 .complete 不留 filtered.json"; fi

# 缺中間一頁：.complete 記的末頁是 3，但只放了第 1、3 頁，第 2 頁不見。這是真實
# 事故的樣子——頁檔存在（不是空目錄），只是不連續，舊的「有沒有任何頁檔」判斷
# 完全看不出來。
printf '3\n' > "$bad_dir/.complete"
cp "$GH_FAKE_BODY" "$bad_dir/0001.json"
cp "$GH_FAKE_BODY" "$bad_dir/0003.json"
rm -f "$bad_dir/0002.json"
lines_before="$(wc -l < "$r" | tr -d ' ')"
out="$(bash "$MRA_DIR/scripts/build-corpus.sh" --repo TanStack/query --filter-only 2>&1)"; rc=$?
if [[ "$rc" != 0 ]]; then ok "缺中間頁時退出非 0"; else fail "缺中間頁卻退出 0"; fi
case "$out" in *CACHE_INCOMPLETE*) ok "缺中間頁訊息含 CACHE_INCOMPLETE" ;; *) fail "缺 CACHE_INCOMPLETE：$out" ;; esac
if printf '%s\n' "$out" | grep -qx '2'; then ok "印出缺的頁碼 2"; else fail "沒印出缺的頁碼：$out"; fi
eq "缺中間頁不寫留存列" "$lines_before" "$(wc -l < "$r" | tr -d ' ')"
if [[ -e "$bad_dir/filtered.json" ]]; then fail "缺中間頁卻留下 filtered.json"; else ok "缺中間頁不留 filtered.json"; fi

# 把 bad_dir 收回一個乾淨、完整的單頁狀態：本檔案結尾的並行測試會用完整目標
# 清單重新跑一次 fetch+filter（TanStack/query 也在清單裡），殘留的第 3 頁與缺頁
# 狀態不清掉的話會讓那段測試的前提變得不乾淨。
rm -f "$bad_dir/0002.json" "$bad_dir/0003.json"
printf '%s' "$(cat "$GH_FAKE_BODY")" > "$bad_dir/0001.json"
printf '1\n' > "$bad_dir/.complete"

# Fix 2：filtered.json.tmp -> filtered.json 這個 mv 沒檢查退出碼的話，磁碟滿、
# 或 TMPDIR 與快取目錄跨檔案系統時 mv 退化成 copy+unlink 又失敗，都會被吞掉——
# 退出 0、留存列照樣寫「留了 N 則」，但 filtered.json 其實還是上一次成功執行的
# 舊輸出。用 PATH shim 讓 mv 只在搬移 filtered.json.tmp -> filtered.json 這一步
# 失敗，其餘 mv（corpus_fetch_page 內部搬頁檔、retention.tsv 的搬移）照常放行，
# 才不會連帶測壞其他步驟。
mkdir -p "$TMP/mvbin"
cat > "$TMP/mvbin/mv" <<'SHIM'
#!/usr/bin/env bash
case "$*" in
  *filtered.json.tmp*filtered.json) exit 1 ;;
esac
command -p mv "$@"
SHIM
chmod +x "$TMP/mvbin/mv"

mv_dir="$TMP/cache/prisma__prisma"
lines_before="$(wc -l < "$r" | tr -d ' ')"
out="$(PATH="$TMP/mvbin:$PATH" bash "$MRA_DIR/scripts/build-corpus.sh" --repo prisma/prisma 2>&1)"; rc=$?
if [[ "$rc" != 0 ]]; then ok "mv 失敗時退出非 0"; else fail "mv 失敗卻退出 0"; fi
case "$out" in *FILTER_PROMOTE_FAILED*) ok "訊息含 FILTER_PROMOTE_FAILED" ;; *) fail "缺 FILTER_PROMOTE_FAILED：$out" ;; esac
eq "mv 失敗不寫留存列" "$lines_before" "$(wc -l < "$r" | tr -d ' ')"
if [[ -e "$mv_dir/filtered.json" ]]; then fail "mv 失敗卻留下 filtered.json"; else ok "mv 失敗不留 filtered.json"; fi
if [[ -e "$mv_dir/filtered.json.tmp" ]]; then fail "mv 失敗留下 filtered.json.tmp"; else ok "mv 失敗不留 filtered.json.tmp"; fi

# 先成功再失敗：確認 mv 失敗會把「上一次成功的 filtered.json」也清掉，不是留著
# 讓它看起來像是這次的結果——跟合併失敗、篩選失敗那兩條分支的要求一致。
out2="$(bash "$MRA_DIR/scripts/build-corpus.sh" --repo prisma/prisma --filter-only 2>&1)"; rc2=$?
eq "先跑成功：退出 0" "0" "$rc2"
if [[ -s "$mv_dir/filtered.json" ]]; then ok "先成功：filtered.json 有產出"; else fail "先成功：沒產出"; fi
PATH="$TMP/mvbin:$PATH" bash "$MRA_DIR/scripts/build-corpus.sh" --repo prisma/prisma --filter-only >/dev/null 2>&1
rc3=$?
if [[ "$rc3" != 0 ]]; then ok "再失敗：退出非 0"; else fail "再失敗：退出 0"; fi
if [[ -e "$mv_dir/filtered.json" ]]; then fail "mv 失敗後舊的 filtered.json 還在"; else ok "mv 失敗後移除舊的 filtered.json"; fi

# --internal：抓 + 篩走 corpus_internal_targets / corpus_filter_all_internal，
# 第 2 步改用活躍留言者而不是 author_association。gh shim 對 --jq 的支援見上方。
out="$(bash "$MRA_DIR/scripts/build-corpus.sh" --internal --repo acme/rails-app-1 2>&1)"; rc=$?
eq "internal 退出碼 0" "0" "$rc"
f_int="$TMP/cache/acme__rails-app-1/filtered.json"
if [[ -s "$f_int" ]]; then ok "internal filtered.json 產出"; else fail "internal filtered.json 沒產出"; fi
eq "internal 篩選後 2 筆" "2" "$(jq 'length' "$f_int")"
eq "internal ids" "[5,9]" "$(jq -c '[.[].id]' "$f_int")"
eq "internal 帶 layer" "rails" "$(jq -r '.[0].layer' "$f_int")"
eq "internal 留存數那行" "acme/rails-app-1	10	7	4	3	2" "$(grep '^acme/rails-app-1	' "$r")"

# 未知 repo（不在自家清單）也要拒絕，跟外部版一致
if bash "$MRA_DIR/scripts/build-corpus.sh" --internal --repo no/such-repo >/dev/null 2>&1; then
  fail "--internal 未知 repo 應退出非 0"
else
  ok "--internal 未知 repo 退出非 0"
fi

# 留存去重必須是字串比對，這裡走真正的 CLI（不是在測試檔裡重打一遍 awk 運算式）。
# acme/nest-monorepo-2.0 是 Task 6 自家目標清單裡真實存在的名字；如果腳本裡的去重被
# 換回 `grep -v "^$repo\t"`，這裡會把 acme/nest-monorepo-2X0 那個不相干的列一起清掉，
# 而 Task 4 的目標清單裡沒有任何含 metachar 的名稱，這條路徑只有在這裡才踩得到。
dsp_dir="$TMP/cache/acme__nest-monorepo-2.0"
mkdir -p "$dsp_dir"
cp "$GH_FAKE_BODY" "$dsp_dir/0001.json"
# 同理補 .complete：沒有它的話 Fix 1(c) 會在完整性檢查那一層就擋下來，
# 這條測試要驗的去重路徑（成功篩選後改寫這一列）就永遠跑不到，斷言雖然還是綠的，
# 但測不到它原本要測的東西。
printf '1\n' > "$dsp_dir/.complete"
printf 'acme/nest-monorepo-2.0\t1\t1\t1\t1\t1\n' >> "$r"
printf 'acme/nest-monorepo-2X0\t9\t9\t9\t9\t9\n' >> "$r"
bash "$MRA_DIR/scripts/build-corpus.sh" --internal --repo acme/nest-monorepo-2.0 --filter-only >/dev/null 2>&1
eq "metachar CLI：decoy 列還在" "1" "$(grep -c '^acme/nest-monorepo-2X0	' "$r")"
eq "metachar CLI：自己那列只有一份" "1" "$(grep -c '^acme/nest-monorepo-2\.0	' "$r")"

# Step 5a：留存報告的讀改寫要互斥。--internal 讓外部與自家兩種模式共用同一份
# retention.tsv：外部語料在一個視窗、自家語料在另一個視窗同時跑是很自然的加速
# 做法，去重是「讀全檔 → 濾掉自己那列 → 寫回」，交錯執行會靜默丟掉對方剛寫的列。
#
# 每個行程只處理一個 repo 的話，去重臨界區太短，兩個行程幾乎不會真的疊在一起，
# 拿掉鎖也測不出來（實測過：單一 repo 配對跑了 70 輪都沒抓到）。改成兩個行程
# 各自跑完整份清單（外部 10 個、自家 10 個），每個行程會進臨界區 10 次，才有
# 夠高的機率真的撞在一起；也更貼近這條鎖真正要防的情境。
# 沒有鎖的話這條會間歇性失敗，所以連跑 5 次確認穩定。
lock_ok=1
for i in 1 2 3 4 5; do
  printf 'repo\tn0_raw\tn1_nobot\tn2_senior\tn3_quality\tn4_prose\n' > "$r"
  bash "$MRA_DIR/scripts/build-corpus.sh" >/dev/null 2>&1 &
  pid1=$!
  bash "$MRA_DIR/scripts/build-corpus.sh" --internal >/dev/null 2>&1 &
  pid2=$!
  wait "$pid1" "$pid2"
  headers="$(grep -c '^repo	' "$r" 2>/dev/null || true)"
  total_lines="$(grep -c . "$r" 2>/dev/null || true)"
  data_rows=$(( ${total_lines:-0} - ${headers:-0} ))
  if [[ "${headers:-0}" != "1" || "$data_rows" != "20" ]]; then
    lock_ok=0
    # ${data_rows} 要用大括號：bash 在某些 ctype/locale 組合下，$data_rows 後面緊接著
    # 全形字元（如「（」）的第一個位元組會被誤判成識別字元的一部分，讓變數名稱
    # 變成「data_rows」加一個不存在的位元組而觸發 unbound variable，把整個測試腳本
    # 中止掉而不是乾淨地印出 FAIL。加大括號明確界定變數名稱邊界可以避開這個問題。
    fail "並行寫入第 $i 輪：表頭=${headers}，資料列=${data_rows}（預期 20：外部 10 + 自家 10）"
  fi
done
[[ "$lock_ok" == 1 ]] && ok "並行寫入 retention.tsv 五輪皆穩定（表頭唯一、20 列皆在）"

# Fix round 2：_retention_unlock 只能釋放自己持有的鎖，不能無條件 rm -rf。
# 等 300 秒放棄取鎖的行程並沒有真的拿到鎖，但結束時 EXIT trap 一樣會觸發
# _retention_unlock；無條件版本會把另一個行程正在合法持有的鎖砍掉，兩個行程
# 又同時進臨界區——跟 Fix round 1 修掉的陳舊判斷問題是同一種失效模式的另一條路。
#
# 用函式層級的測試直接驗證，比並行測試更清楚也更穩定。從真正的腳本原始碼裡把
# 鎖函式的定義抽出來（用固定的起訖字串當錨點，不是在測試裡另外抄一份）：抄一份
# 的話正式碼被改壞，這裡不會變紅，等於白測。抽出來丟進一個全新的 bash 行程執行，
# 用環境變數控制 RETENTION 路徑跟 _RETENTION_LOCK_HELD 的初始值。
lock_start="$(grep -n '^_retention_lock_mtime() {' "$MRA_DIR/scripts/build-corpus.sh" | head -1 | cut -d: -f1)"
lock_end="$(grep -n "^trap '_retention_unlock' EXIT" "$MRA_DIR/scripts/build-corpus.sh" | head -1 | cut -d: -f1)"
lock_end=$((lock_end - 1))
lock_unit="$(mktemp "${TMPDIR:-/tmp}/corpus-lock-unit.XXXXXX")"
{
  echo 'set -uo pipefail'
  sed -n "${lock_start},${lock_end}p" "$MRA_DIR/scripts/build-corpus.sh"
  cat <<'DRIVER'
mkdir -p "$RETENTION.lock"
_RETENTION_LOCK_HELD="$HELD"
_retention_unlock
if [[ -d "$RETENTION.lock" ]]; then echo STILL_THERE; else echo GONE; fi
DRIVER
} > "$lock_unit"

lock_test_target="$TMP/cache/lock-unit-test"
out1="$(RETENTION="$lock_test_target" HELD=0 bash "$lock_unit")"
eq "沒持有鎖時 _retention_unlock 不動別人的鎖" "STILL_THERE" "$out1"
out2="$(RETENTION="$lock_test_target" HELD=1 bash "$lock_unit")"
eq "持有鎖時 _retention_unlock 會釋放" "GONE" "$out2"
rm -f "$lock_unit"

echo "---"; echo "Passed: $pass"; echo "Failed: $errors"
exit $((errors > 0 ? 1 : 0))
