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

echo "---"; echo "Passed: $pass"; echo "Failed: $errors"
exit $((errors > 0 ? 1 : 0))
