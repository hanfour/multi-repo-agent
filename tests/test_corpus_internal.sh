#!/usr/bin/env bash
# 自家語料取材 (lib/corpus-internal.sh)。
set -uo pipefail
MRA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# MRA_CORPUS_DIR 要指到本測試專屬的目錄，理由同 tests/test_build_corpus.sh：
# 不設的話 corpus_cache_dir 會退回 $HOME/.cache/mra-review-corpus，跑這條測試
# 會動到使用者真正的快取，而且平行測試檔之間會互相污染 retention.tsv。
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export MRA_CORPUS_DIR="$TMP/cache"
mkdir -p "$MRA_CORPUS_DIR"

source "$MRA_DIR/lib/corpus-filter.sh"
source "$MRA_DIR/lib/corpus-internal.sh"
FX="$MRA_DIR/tests/fixtures/corpus/sample-comments.json"

errors=0; pass=0
ok()   { echo "PASS: $1"; pass=$((pass+1)); }
fail() { echo "FAIL: $1"; errors=$((errors+1)); }
eq()   { if [[ "$2" == "$3" ]]; then ok "$1"; else fail "$1 — expected [$2] got [$3]"; fi; }

# 目標清單：五層都要有代表，且 PR 量最高的 erp 要在
bad_cols=$(corpus_internal_targets | awk -F'\t' 'NF != 2' | wc -l | tr -d ' ')
eq "每行兩欄" "0" "$bad_cols"
for r in acme/rails-app-1 acme/nest-monorepo-2.0 acme/react-app-1 acme/vue-app-1; do
  if corpus_internal_targets | cut -f1 | grep -qx "$r"; then ok "含 $r"; else fail "缺 $r"; fi
done

# corpus_internal_layer_of：分層注入靠它決定每個 PR 要讀哪一層的規則
# （scripts/run-backtest.sh 的 MRA_PERSONAS_ROOT 那段）。查不到時必須退出
# 非 0 而不是印出空字串——呼叫端要分得出「這個 repo 屬於通用層」與「這個
# repo 還沒登記」，兩者的正確處置完全不同：前者照跑，後者該擋下來。
eq "erp 是 rails 層" "rails" "$(corpus_internal_layer_of acme/rails-app-1)"
eq "nest-monorepo-2.0 是 nestjs 層" "nestjs" "$(corpus_internal_layer_of acme/nest-monorepo-2.0)"
eq "react-app-1 是 react 層" "react" "$(corpus_internal_layer_of acme/react-app-1)"
eq "oss-ui-v2 是 vue 層" "vue" "$(corpus_internal_layer_of acme/vue-app-1)"
if corpus_internal_layer_of someorg/never-registered >/dev/null 2>&1; then
  fail "沒登記的 repo 應退出非 0"
else
  ok "沒登記的 repo 退出非 0"
fi
eq "沒登記的 repo 什麼都不印" "" "$(corpus_internal_layer_of someorg/never-registered)"
# 比對必須是字串相等，不是正規表示式：acme/nest-monorepo-2X0 不在清單裡，把 .
# 當萬用字元的實作會把它誤配成 nestjs 層，那個 repo 的 PR 就會讀到一份不屬於
# 它的規則，而外觀上完全正常。
eq "含 . 的名稱不會被當成萬用字元" "" "$(corpus_internal_layer_of acme/nest-monorepo-2X0)"

# 第 2 步改用活躍留言者清單，不看 author_association。
# fixture 裡 member1 有 4 則、member2 與 member3 各 1 則、outsider 1 則。
active='["member1"]'
eq "只留 member1" "[4,5,8,9]" "$(corpus_filter_bots < "$FX" | corpus_filter_active "$active" | jq -c '[.[].id]')"

# outsider 在 GitHub 上是 NONE，但只要留言夠多就該留下：
# 這正是自家 repo 與外部 repo 的差別。
active2='["member1","outsider"]'
eq "NONE 也能留下" "[3,4,5,8,9]" "$(corpus_filter_bots < "$FX" | corpus_filter_active "$active2" | jq -c '[.[].id]')"

# 完整管線的 stdout / stderr 契約與外部版一致
err="$(mktemp "${TMPDIR:-/tmp}/corpus-internal-test.XXXXXX")"
outn="$(corpus_filter_all_internal acme/rails-app-1 rails "$active" < "$FX" 2>"$err" | jq 'length')"
# 留 2 筆（id 5、9）。id 4 短且無回覆無 reaction 被第 3 步濾掉，
# id 8 只有 suggestion 區塊沒有說明文字被第 4 步濾掉。
eq "自家管線留 2" "2" "$outn"
eq "自家管線 ids" "[5,9]" "$(corpus_filter_all_internal acme/rails-app-1 rails "$active" < "$FX" 2>/dev/null | jq -c '[.[].id]')"
case "$(cat "$err")" in RETENTION*acme/rails-app-1*) ok "留存數 TSV 格式一致" ;; *) fail "TSV 格式不對：$(cat "$err")" ;; esac
rm -f "$err"

# corpus_active_reviewers 要有直接測試。實測過：沒有這些斷言的話，把門檻的 >= 改成 >
# （邊界差一）與拿掉 corpus_filter_all_internal 的輸入守衛，兩個 mutation 套件都不會紅，
# 因為它只被 --internal 的整合測試間接跑到，而那條路徑的 gh shim 每頁回同一份 fixture，
# 計數遠超門檻，邊界永遠碰不到。
mkdir -p "$TMP/ar"
cat > "$TMP/ar/gh" <<'ARSHIM'
#!/usr/bin/env bash
# 判斷「是不是 page=1」不能用 *"page=1"*：查詢字串裡固定帶的 per_page=100
# 本身就含 "page=1" 這個子字串（per_PAGE=1_00），page=2、page=3 的請求一樣會
# 誤判成 page=1，等於完全沒有 gate 到。實測過，用 grep -c 對三種 page 值各驗一次：
#   page=1 的網址 → 含 "&page=1&" 也含裸的 "page=1"（都算命中，符合預期）
#   page=2 的網址 → 不含 "&page=1&"，但仍然含裸的 "page=1"（per_page=100 那段）
# 改用 *"&page=1&"* 帶前後的 & 分隔字元，才真的只匹配 page=1 那一次呼叫。
case "$AR_MODE" in
  # 三個人分別 10、9、1 則：剛好在門檻上、差一則、遠低於門檻。
  # 只在 page=1 回資料：corpus_active_reviewers 固定跑三頁，這裡若跟 nobody 一樣
  # 三頁都回同一批，10/9/1 會被乘成 30/27/3，min=10 時 27>=10 讓「差一則」也跟著
  # 通過，「剛好達門檻」跟「差一則不留」兩條斷言就分不出來了——原始的 plan 範例
  # 沒有這個 page 判斷（而且範例用的 *page=1* 寫法本身也踩了上面那個 per_page
  # 誤判的坑），實測會產生 ["exactly10","nine"]，不是預期的 ["exactly10"]。
  boundary) [[ "$*" == *"&page=1&"* ]] && { printf 'exactly10\n%.0s' $(seq 10); printf 'nine\n%.0s' $(seq 9); echo lonely; }; ;;
  onepage)  [[ "$*" == *"&page=1&"* ]] && { printf 'solo\n%.0s' $(seq 12); }; ;;  # 只有第一頁有資料
  nobody)   echo drive-by ;;                                                     # 沒有人達標
  allfail)  exit 1 ;;                                                            # 三頁全失敗
  # 2/3、1/3 頁成功：舊版只要 ok=1（至少一頁成功）就把絕對門檻套在殘缺樣本上，
  # 活躍者因此悄悄變少。這裡讓失敗的那幾頁直接 exit 1，成功的頁印出遠超門檻
  # 的計數，確保「回傳非空陣列」不是因為門檻剛好也被殘缺樣本打中。
  partial2) [[ "$*" == *"&page=3&"* ]] && exit 1; printf 'active\n%.0s' $(seq 10) ;;
  partial1) [[ "$*" == *"&page=1&"* ]] || exit 1; printf 'active\n%.0s' $(seq 10) ;;
esac
exit 0
ARSHIM
chmod +x "$TMP/ar/gh"

ar() { PATH="$TMP/ar:$PATH" AR_MODE="$1" corpus_active_reviewers x/y "${2:-10}"; }

eq "剛好達門檻要留下"   '["exactly10"]' "$(ar boundary 10)"
eq "差一則不留"         '["exactly10"]' "$(ar boundary 10)"
eq "門檻調到 9 則兩人"  '["exactly10","nine"]' "$(ar boundary 9 | jq -c 'sort')"
eq "不足三頁也能算"     '["solo"]'      "$(ar onepage 10)"
eq "沒人達標回空陣列"   '[]'            "$(ar nobody 10)"
if ar allfail 10 >/dev/null 2>&1; then fail "三頁全失敗應退出非 0"; else ok "三頁全失敗退出非 0"; fi
eq "空陣列不會弄壞下游" "0" "$(printf '[]' | corpus_filter_active "$(ar nobody 10)" | jq 'length')"

# 三頁裡有頁失敗（不是全部失敗）也要退出非 0，不能只看「有沒有任何一頁成功」。
# 舊版的 ok=1 只要有一頁成功就繼續往下算，等於拿絕對門檻去套殘缺樣本，活躍者
# 因此悄悄消失，下游看起來會跟「這個 repo 真的沒有活躍的 reviewer」一模一樣。
partial_err="$(mktemp "${TMPDIR:-/tmp}/corpus-internal-partial.XXXXXX")"
if PATH="$TMP/ar:$PATH" AR_MODE=partial2 corpus_active_reviewers x/y 10 >/dev/null 2>"$partial_err"; then
  fail "2/3 頁成功應退出非 0"
else
  ok "2/3 頁成功退出非 0"
fi
case "$(cat "$partial_err")" in
  ACTIVE_REVIEWERS_PARTIAL*x/y*2/3*) ok "2/3 頁成功印出 ACTIVE_REVIEWERS_PARTIAL 與 2/3" ;;
  *) fail "缺 ACTIVE_REVIEWERS_PARTIAL 或欄位不對：$(cat "$partial_err")" ;;
esac

if PATH="$TMP/ar:$PATH" AR_MODE=partial1 corpus_active_reviewers x/y 10 >/dev/null 2>"$partial_err"; then
  fail "1/3 頁成功應退出非 0"
else
  ok "1/3 頁成功退出非 0"
fi
case "$(cat "$partial_err")" in
  ACTIVE_REVIEWERS_PARTIAL*x/y*1/3*) ok "1/3 頁成功印出 ACTIVE_REVIEWERS_PARTIAL 與 1/3" ;;
  *) fail "缺 ACTIVE_REVIEWERS_PARTIAL 或欄位不對：$(cat "$partial_err")" ;;
esac
rm -f "$partial_err"

# corpus_filter_all_internal 的輸入守衛要有直接測試。
# 光看退出碼不夠：拿掉守衛之後，壞輸入還是會在第一個 jq 階段（corpus_filter_bots）
# 自己解析失敗，一樣退出非 0，「應退出非 0」這種寫法測不出守衛被拿掉——實測過，
# 拿掉 `type == "array"` 那段守衛後，這兩條斷言原封不動地維持綠燈。要驗到守衛本身，
# 必須連 stderr 一起檢查：守衛在時是 FILTER_INPUT_INVALID，守衛不在時是
# FILTER_STAGE_FAILED...bots（downstream 自己噴的），兩者都退出非 0 但訊息不同。
guard_err="$(mktemp "${TMPDIR:-/tmp}/corpus-internal-guard.XXXXXX")"
printf '{not json' | corpus_filter_all_internal r l '["x"]' >/dev/null 2>"$guard_err"; rc=$?
eq "壞輸入退出非 0" "1" "$rc"
case "$(cat "$guard_err")" in
  FILTER_INPUT_INVALID*) ok "壞輸入印出 FILTER_INPUT_INVALID" ;;
  *) fail "缺 FILTER_INPUT_INVALID（守衛沒被觸發）：$(cat "$guard_err")" ;;
esac
printf '{"a":1}' | corpus_filter_all_internal r l '["x"]' >/dev/null 2>"$guard_err"; rc=$?
eq "非陣列退出非 0" "1" "$rc"
case "$(cat "$guard_err")" in
  FILTER_INPUT_INVALID*) ok "非陣列印出 FILTER_INPUT_INVALID" ;;
  *) fail "缺 FILTER_INPUT_INVALID（守衛沒被觸發）：$(cat "$guard_err")" ;;
esac
rm -f "$guard_err"

# 留存去重必須是字串比對。acme/nest-monorepo-2.0 的那個點如果被當成正規表示式，
# 會連 acme/nest-monorepo-2X0 這種不相干的列一起刪掉。Task 4 的目標清單裡沒有含
# metachar 的名稱，所以這條回歸測試只能放在這裡。
R="$MRA_CORPUS_DIR/retention.tsv"
mkdir -p "$MRA_CORPUS_DIR"
printf 'repo\tn0_raw\tn1_nobot\tn2_senior\tn3_quality\tn4_prose\n' > "$R"
printf 'acme/nest-monorepo-2.0\t1\t1\t1\t1\t1\n' >> "$R"
printf 'acme/nest-monorepo-2X0\t9\t9\t9\t9\t9\n' >> "$R"
CORPUS_REPO="acme/nest-monorepo-2.0" awk -F'\t' 'NR == 1 || $1 != ENVIRON["CORPUS_REPO"]' "$R" > "$R.probe"
eq "含 . 的名稱只刪自己那列" "1" "$(grep -c '^acme/nest-monorepo-2X0	' "$R.probe")"
eq "自己那列有刪掉" "0" "$(grep -c '^acme/nest-monorepo-2\.0	' "$R.probe")"
rm -f "$R.probe"

echo "---"; echo "Passed: $pass"; echo "Failed: $errors"
exit $((errors > 0 ? 1 : 0))
