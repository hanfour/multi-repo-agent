#!/usr/bin/env bash
# 回測執行 (scripts/run-backtest.sh)。用 PATH shim 假造 mra，不呼叫 LLM、不連網路。
#
# 主要基準集用四筆 confirmed=true 的 PR：期望數不均(1、3、7 筆)，而且每筆的
# 「comment 數」跟「expected_findings 數」刻意不成比例(α：2 comment／1 筆
# expected；β：3 comment／3 筆；γ：4 comment／7 筆)——不是隨便挑的。攤平多個
# PR 的 match／comment 陣列時，位移量必須以「目前已經攤平的 comment 筆數」為
# 準，不能誤用「目前已經攤平的 match 筆數」；如果兩個來源在每一步的累積值都
# 剛好一樣，這兩種寫法會算出同一個答案，測試就完全看不出來哪個用錯了。α 的
# 命中 comment 刻意排在第二個位置(前面先放一則不相關的 noise comment)，讓
# 「用 match 累積數當位移」在 β 那步算出的位置跟 α 自己的 unmatched comment
# 撞在一起——這個撞擊會讓好幾個 comment 的攤平位置真的重疊，使用錯誤位移
# 來源時 unmatched 的「總數」本身就會算錯，不只是誰對應到誰的標籤錯。
# 另外一筆 review 會失敗(δ)，一筆 expected_findings 是空陣列(ε，仍然
# confirmed=true，要照跑)，一筆 confirmed=false、一筆 confirmed=null。
# baseline／after 兩個 label 餵完全不同的 mra 輸出，讓 --compare 的兩欄本來
# 就該不同，才驗得出欄位有沒有被弄混。
set -uo pipefail
MRA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
S="$MRA_DIR/scripts/run-backtest.sh"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/run-backtest-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
export MRA_BENCHMARK_DIR="$TMP/bench"
mkdir -p "$MRA_BENCHMARK_DIR" "$TMP/bin"
export MRA_BACKTEST_CMD="mra"
export PATH="$TMP/bin:$PATH"

errors=0; pass=0
ok()   { echo "PASS: $1"; pass=$((pass+1)); }
fail() { echo "FAIL: $1"; errors=$((errors+1)); }
eq()   { if [[ "$2" == "$3" ]]; then ok "$1"; else fail "$1 — expected [$2] got [$3]"; fi; }
has()  { case "$2" in *"$3"*) ok "$1" ;; *) fail "$1 — 沒看到「$3」：$2" ;; esac; }
lacks(){ case "$2" in *"$3"*) fail "$1 — 不該看到「$3」：$2" ;; *) ok "$1" ;; esac; }

C="$MRA_BENCHMARK_DIR/candidates.json"

# --- 基準集 --------------------------------------------------------------
# 8101=α(1 筆 expected、2 則 comment、1 則命中，命中的那則排第二)
# 8102=β(3 筆 expected、3 則 comment、3 則命中)
# 8103=γ(7 筆 expected、4 則 comment、3 則命中)
# 8104=δ(review 會失敗)
# 8105=ε(expected_findings 空陣列，但仍是 confirmed=true，要照跑)
# 8106=confirmed=false　8107=confirmed=null
cat > "$C" <<'J'
[
 {"repo":"acme/rails-app-1","pr":8101,"merged_at":"2026-08-01T00:00:00Z","fix_commits":[],
  "confirmed":true,
  "expected_findings":[{"path":"app/a.rb","line":10,"severity":"HIGH","note":"a"}]},
 {"repo":"acme/rails-app-1","pr":8102,"merged_at":"2026-08-02T00:00:00Z","fix_commits":[],
  "confirmed":true,
  "expected_findings":[
   {"path":"app/b1.rb","line":20,"severity":"HIGH","note":"b1"},
   {"path":"app/b2.rb","line":40,"severity":"MEDIUM","note":"b2"},
   {"path":"app/b3.rb","line":60,"severity":"LOW","note":"b3"}]},
 {"repo":"acme/rails-app-1","pr":8103,"merged_at":"2026-08-03T00:00:00Z","fix_commits":[],
  "confirmed":true,
  "expected_findings":[
   {"path":"app/c1.rb","line":1,"severity":"HIGH","note":"c1"},
   {"path":"app/c2.rb","line":2,"severity":"HIGH","note":"c2"},
   {"path":"app/c3.rb","line":3,"severity":"HIGH","note":"c3"},
   {"path":"app/c4.rb","line":4,"severity":"HIGH","note":"c4"},
   {"path":"app/c5.rb","line":5,"severity":"HIGH","note":"c5"},
   {"path":"app/c6.rb","line":6,"severity":"HIGH","note":"c6"},
   {"path":"app/c7.rb","line":7,"severity":"HIGH","note":"c7"}]},
 {"repo":"acme/rails-app-1","pr":8104,"merged_at":"2026-08-04T00:00:00Z","fix_commits":[],
  "confirmed":true,
  "expected_findings":[{"path":"app/x.rb","line":1,"severity":"HIGH","note":"x"}]},
 {"repo":"acme/rails-app-1","pr":8105,"merged_at":"2026-08-05T00:00:00Z","fix_commits":[],
  "confirmed":true,"expected_findings":[]},
 {"repo":"acme/rails-app-1","pr":8106,"merged_at":"2026-08-06T00:00:00Z","fix_commits":[],
  "confirmed":false,"expected_findings":[]},
 {"repo":"acme/rails-app-1","pr":8107,"merged_at":"2026-08-07T00:00:00Z","fix_commits":[],
  "confirmed":null,"expected_findings":[]}
]
J

# 手算(baseline，加總後才算一次率)：
#   expected_total = 1+3+7+0(ε) = 11
#   missed         = 0+0+4+0   = 4   → miss_rate      = 4/11  = 0.3636 → 0.36
#   comments_total = 2+3+4+2   = 11
#   unmatched      = 1+0+1+2   = 4   → unmatched_rate = 4/11  = 0.3636 → 0.36
#   severity_agree = 1+3+2+0   = 6   (命中數 1+3+3+0=7)  severity_rate = 6/7 = 0.86
# 這組數字已經用真正跑過 scripts/run-backtest.sh 驗證過；同一份 fixture 若把
# 位移來源改成用 match 累積數(而不是 comment 累積數)，跑出來的 unmatched 會是
# 5、unmatched_rate 會是 0.45——本檔只認 4／0.36。

# --- mra shim：baseline label -------------------------------------------
cat > "$TMP/bin/mra" <<'SHIM'
#!/usr/bin/env bash
case "$*" in
  *"--pr 8101"*)
    printf '%s' '{"status":"CHANGES_REQUESTED","summary":"x","comments":[
     {"path":"app/noise1.rb","line":1,"body":"x","severity":"LOW"},
     {"path":"app/a.rb","line":11,"body":"x","severity":"HIGH"}]}' ;;
  *"--pr 8102"*)
    printf '%s' '{"status":"CHANGES_REQUESTED","summary":"x","comments":[
     {"path":"app/b1.rb","line":21,"body":"x","severity":"HIGH"},
     {"path":"app/b2.rb","line":41,"body":"x","severity":"MEDIUM"},
     {"path":"app/b3.rb","line":60,"body":"x","severity":"LOW"}]}' ;;
  *"--pr 8103"*)
    printf '%s' '{"status":"CHANGES_REQUESTED","summary":"x","comments":[
     {"path":"app/c1.rb","line":1,"body":"x","severity":"HIGH"},
     {"path":"app/c2.rb","line":2,"body":"x","severity":"HIGH"},
     {"path":"app/c3.rb","line":3,"body":"x","severity":"MEDIUM"},
     {"path":"app/extra5.rb","line":99,"body":"x","severity":"LOW"}]}' ;;
  *"--pr 8104"*)
    echo "codex transient failure (ec=142)" >&2
    exit 1 ;;
  *"--pr 8105"*)
    # status 故意用 CHANGES_REQUESTED，不是 COMMENT：inline schema 底下
    # COMMENT 專屬於 REVIEW_INCOMPLETE(見 lib/review.sh)，一份帶著 2 筆真的
    # comments 的完整 review 不可能合法地是 COMMENT。這裡就是要測「零期望
    # findings 不代表零 comments」，用 COMMENT 反而會被新加的
    # REVIEW_INCOMPLETE 檢查誤判成沒跑完而排除，語意上就錯了。
    printf '%s' '{"status":"CHANGES_REQUESTED","summary":"x","comments":[
     {"path":"app/e1.rb","line":1,"body":"x","severity":"LOW"},
     {"path":"app/e2.rb","line":2,"body":"x","severity":"LOW"}]}' ;;
  *"--pr 8106"*|*"--pr 8107"*)
    printf '%s' '{"status":"APPROVED","summary":"x","comments":[]}' ;;
  *)
    echo "unexpected mra invocation: $*" >&2; exit 1 ;;
esac
SHIM
chmod +x "$TMP/bin/mra"

err_baseline="$TMP/baseline.err"
bash "$S" --label baseline >"$TMP/baseline.out" 2>"$err_baseline"
rc=$?
eq "baseline 退出碼 0" "0" "$rc"

R="$MRA_BENCHMARK_DIR/runs/baseline"
if [[ -s "$R/acme__rails-app-1__8101.json" ]]; then ok "8101(α) 有輸出檔"; else fail "沒跑 8101"; fi
if [[ -s "$R/acme__rails-app-1__8102.json" ]]; then ok "8102(β) 有輸出檔"; else fail "沒跑 8102"; fi
if [[ -s "$R/acme__rails-app-1__8103.json" ]]; then ok "8103(γ) 有輸出檔"; else fail "沒跑 8103"; fi
if [[ -s "$R/acme__rails-app-1__8105.json" ]]; then ok "8105(ε，expected_findings 空陣列) 有輸出檔"; else fail "沒跑 8105"; fi
if [[ -e "$R/acme__rails-app-1__8104.json" ]]; then fail "8104 review 失敗不該留檔"; else ok "8104 review 失敗沒有殘留輸出檔"; fi
if [[ -e "$R/acme__rails-app-1__8106.json" ]]; then fail "不該跑 confirmed=false 的 8106"; else ok "跳過 confirmed=false(8106)"; fi
if [[ -e "$R/acme__rails-app-1__8107.json" ]]; then fail "不該跑 confirmed=null 的 8107"; else ok "跳過 confirmed=null(8107)"; fi

eq "8105(ε) 自己的 comment 數是 2(expected 空不代表不能有 comment)" "2" \
  "$(jq '.comments | length' "$R/acme__rails-app-1__8105.json")"

err_baseline_text="$(cat "$err_baseline")"
has  "8104 review 失敗有印出 REVIEW_FAILED" "$err_baseline_text" "REVIEW_FAILED"
has  "REVIEW_FAILED 訊息指名 8104" "$err_baseline_text" "acme/rails-app-1#8104"

S1="$R/summary.json"
eq "prs 數為 4(8104/8106/8107 都不計入)"  "4"    "$(jq -r '.prs' "$S1")"
eq "期望總數 11(1+3+7+0 加總)"            "11"   "$(jq -r '.expected_total' "$S1")"
eq "漏抓數 4(加總，非逐 PR 平均)"          "4"    "$(jq -r '.missed' "$S1")"
eq "漏抓率 0.36(加總後算一次)"             "0.36" "$(jq -r '.miss_rate' "$S1")"
eq "comment 總數 11(加總)"                "11"   "$(jq -r '.comments_total' "$S1")"
eq "未對應數 4(位移要以 comment 累積數為準，不是 match 累積數)" "4" \
  "$(jq -r '.unmatched' "$S1")"
eq "未對應率 0.36"                        "0.36" "$(jq -r '.unmatched_rate' "$S1")"
eq "嚴重度吻合數 6"                       "6"    "$(jq -r '.severity_agree' "$S1")"
eq "嚴重度吻合率 0.86"                     "0.86" "$(jq -r '.severity_rate' "$S1")"

# --- REVIEW_FAILED(8104)不只印到 stderr，也要進 summary.json ---------------
eq "failed_count 是 1(8104)"              "1"    "$(jq -r '.failed_count' "$S1")"
eq "failed_prs 清單裡有 acme/rails-app-1#8104"   "acme/rails-app-1#8104" "$(jq -r '.failed_prs[0]' "$S1")"
eq "這個基準集沒有 status=COMMENT 的 PR，incomplete_count 是 0" "0" \
  "$(jq -r '.incomplete_count' "$S1")"
eq "incomplete_prs 是空陣列" "[]" "$(jq -c '.incomplete_prs' "$S1")"

# --- REVIEW_FAILED 的 stderr 不再丟進 /dev/null，改存進 .err 檔 ------------
ERR_8104="$R/acme__rails-app-1__8104.err"
if [[ -s "$ERR_8104" ]]; then
  ok "8104 的 .err 檔有寫出診斷內容(不是空的或不存在)"
else
  fail ".err 檔是空的或不存在：$ERR_8104"
fi
has ".err 檔內容包含真正的失敗原因(codex transient failure)" \
  "$(cat "$ERR_8104")" "codex transient failure"
has "REVIEW_FAILED 訊息指出 .err 檔路徑" "$err_baseline_text" "$ERR_8104"

# --- mra shim：after label(輸出跟 baseline 完全不同，--compare 才有東西可比)
cat > "$TMP/bin/mra" <<'SHIM'
#!/usr/bin/env bash
case "$*" in
  *"--pr 8101"*)
    printf '%s' '{"status":"CHANGES_REQUESTED","summary":"x","comments":[
     {"path":"app/a.rb","line":10,"body":"x","severity":"HIGH"}]}' ;;
  *"--pr 8102"*)
    printf '%s' '{"status":"CHANGES_REQUESTED","summary":"x","comments":[
     {"path":"app/b1.rb","line":20,"body":"x","severity":"HIGH"},
     {"path":"app/b2.rb","line":40,"body":"x","severity":"MEDIUM"},
     {"path":"app/b3.rb","line":60,"body":"x","severity":"LOW"}]}' ;;
  *"--pr 8103"*)
    printf '%s' '{"status":"CHANGES_REQUESTED","summary":"x","comments":[
     {"path":"app/c1.rb","line":1,"body":"x","severity":"HIGH"},
     {"path":"app/c2.rb","line":2,"body":"x","severity":"HIGH"},
     {"path":"app/c3.rb","line":3,"body":"x","severity":"MEDIUM"},
     {"path":"app/c4.rb","line":4,"body":"x","severity":"HIGH"}]}' ;;
  *"--pr 8104"*)
    exit 1 ;;
  *"--pr 8105"*)
    printf '%s' '{"status":"APPROVED","summary":"x","comments":[]}' ;;
  *"--pr 8106"*|*"--pr 8107"*)
    printf '%s' '{"status":"APPROVED","summary":"x","comments":[]}' ;;
  *)
    echo "unexpected mra invocation: $*" >&2; exit 1 ;;
esac
SHIM
chmod +x "$TMP/bin/mra"

# 手算(after)：expected_total=11、missed=0+0+3+0=3→miss_rate=3/11=0.27、
# comments_total=1+3+4+0=8、unmatched=0→unmatched_rate=0、
# severity_agree=1+3+3+0=7(命中 8 筆，c3 嚴重度錯)→severity_rate=7/8=0.88。
bash "$S" --label after >"$TMP/after.out" 2>"$TMP/after.err"
eq "after 退出碼 0" "0" "$?"

S2="$MRA_BENCHMARK_DIR/runs/after/summary.json"
eq "after prs 數為 4"        "4"    "$(jq -r '.prs' "$S2")"
eq "after 期望總數 11"       "11"   "$(jq -r '.expected_total' "$S2")"
eq "after 漏抓數 3"          "3"    "$(jq -r '.missed' "$S2")"
eq "after 漏抓率 0.27"       "0.27" "$(jq -r '.miss_rate' "$S2")"
eq "after 未對應數 0"        "0"    "$(jq -r '.unmatched' "$S2")"
eq "after 未對應率 0"        "0"    "$(jq -r '.unmatched_rate' "$S2")"
eq "after 嚴重度吻合數 7"    "7"    "$(jq -r '.severity_agree' "$S2")"
eq "after 嚴重度吻合率 0.88" "0.88" "$(jq -r '.severity_rate' "$S2")"

# --- --compare：baseline 跟 after 的數字明顯不同，兩欄不能互相污染 -------
cmp_out="$(bash "$S" --compare baseline after)"
eq "compare 結束碼 0" "0" "$?"

header_line="$(printf '%-18s %10s %10s' "指標" "baseline" "after")"
has "compare 表頭含兩個 label" "$cmp_out" "$header_line"

miss_line="$(printf '%-18s %10s %10s' "miss_rate" "0.36" "0.27")"
has "compare miss_rate 列 A/B 欄不同(baseline 0.36、after 0.27 沒被弄混)" \
  "$cmp_out" "$miss_line"

sev_line="$(printf '%-18s %10s %10s' "severity_agree" "6" "7")"
has "compare severity_agree 列 A/B 欄不同(baseline 6、after 7 沒被弄混)" \
  "$cmp_out" "$sev_line"

unmatched_line="$(printf '%-18s %10s %10s' "unmatched_rate" "0.36" "0")"
has "compare unmatched_rate 列 A/B 欄不同(baseline 0.36、after 0 沒被弄混)" \
  "$cmp_out" "$unmatched_line"

# --- --compare：label 不存在要乾淨報錯，不是空白或 jq 炸出來的錯 --------
out_nolabel="$(bash "$S" --compare baseline 沒有這個label 2>&1)"
rc_nolabel=$?
eq "compare 對到不存在的 label 退出非 0" "1" "$rc_nolabel"
has "compare 對到不存在的 label 有印出「找不到」" "$out_nolabel" "找不到"

# --- --compare：兩個 label 打成同一個，明講、拒絕，不要印出兩欄一樣的假比較
out_same="$(bash "$S" --compare baseline baseline 2>&1)"
rc_same=$?
eq "compare 同一個 label 比自己退出非 0" "1" "$rc_same"
has "compare 同一個 label 比自己有印出 SAME_LABEL" "$out_same" "SAME_LABEL"

# --- --compare：summary.json 存在但不是合法 JSON，要給乾淨診斷，不是 jq 自己
# 吐出來那種一長串 parse error --------------------------------------------
mkdir -p "$MRA_BENCHMARK_DIR/runs/malformed"
printf 'not valid json {{{' > "$MRA_BENCHMARK_DIR/runs/malformed/summary.json"
out_malformed="$(bash "$S" --compare baseline malformed 2>&1)"
rc_malformed=$?
eq "compare 對到壞掉的 summary.json 退出非 0" "1" "$rc_malformed"
has "compare 對到壞掉的 summary.json 有印出 SUMMARY_MALFORMED" \
  "$out_malformed" "SUMMARY_MALFORMED"
lacks "compare 對到壞掉的 summary.json 不該外漏 jq 自己的 parse error" \
  "$out_malformed" "jq: parse error"

# --- 寫入 summary.json 一定走 tmp→mv：把 baseline 的執行目錄改成唯讀，讓
# 建立 .tmp 這步必然失敗，藉此跟「直接覆寫既有檔案」的寫法分岔——目錄唯讀
# 時仍可以直接截斷覆寫一個已存在的檔案(不需要目錄的寫入權限)，只有「先建
# 一個新檔」這個動作才會被擋下來。所有 confirmed 的 PR 都已經有快取檔，
# 這次重跑不會再呼叫 mra，純粹在測 _write_summary 這段。 --------------
orig_summary="$(cat "$S1")"
chmod 555 "$R"
bash "$S" --label baseline >"$TMP/readonly.out" 2>"$TMP/readonly.err"
rc_readonly=$?
chmod 755 "$R"
eq "唯讀執行目錄下重跑退出非 0" "1" "$rc_readonly"
eq "唯讀目錄寫入失敗時 summary.json 內容不變(不是半殘或被直接覆寫)" \
  "$orig_summary" "$(cat "$S1")"
if [[ -e "$S1.tmp" ]]; then fail "唯讀目錄寫入失敗留下殘留 tmp 檔"; else
  ok "唯讀目錄寫入失敗沒有殘留 tmp 檔"; fi
has "唯讀目錄寫入失敗有印出 SUMMARY_WRITE_FAILED" \
  "$(cat "$TMP/readonly.err")" "SUMMARY_WRITE_FAILED"

# --- 同一個 (repo, pr) 在基準集裡出現兩次：不能悄悄疊加計算兩次，要在開跑
# 前直接拒絕——per-PR 的輸出檔是用 (repo, pr) 當檔名鍵，第二筆會直接讀到
# 第一筆的快取檔、再算一次、再疊加進彙總，是不明顯但會把數字墊高的錯誤。
# 用獨立的 MRA_BENCHMARK_DIR，不要動到上面主要 fixture 的 candidates.json。
DUP_DIR="$TMP/bench-dup"
mkdir -p "$DUP_DIR"
cat > "$DUP_DIR/candidates.json" <<'J'
[
 {"repo":"acme/rails-app-1","pr":9001,"merged_at":"2026-08-01T00:00:00Z","fix_commits":[],
  "confirmed":true,
  "expected_findings":[{"path":"app/a.rb","line":10,"severity":"HIGH","note":"a"}]},
 {"repo":"acme/rails-app-1","pr":9001,"merged_at":"2026-08-01T00:00:00Z","fix_commits":[],
  "confirmed":true,
  "expected_findings":[{"path":"app/a.rb","line":10,"severity":"HIGH","note":"a"}]}
]
J
out_dup="$(MRA_BENCHMARK_DIR="$DUP_DIR" bash "$S" --label dup 2>&1)"
rc_dup=$?
eq "重複 (repo,pr) 退出非 0" "1" "$rc_dup"
has "重複 (repo,pr) 有印出 DUPLICATE_PR" "$out_dup" "DUPLICATE_PR"
has "DUPLICATE_PR 訊息指名 acme/rails-app-1#9001" "$out_dup" "acme/rails-app-1#9001"
if [[ -e "$DUP_DIR/runs/dup/summary.json" ]]; then
  fail "重複 (repo,pr) 不該輸出 summary.json"
else
  ok "重複 (repo,pr) 沒有輸出疊加過的假 summary.json"
fi

# --- --tolerance 真的有被讀進去，不是寫死：同一則 comment 離 expected 3 行，
# 預設容差(5)內會命中；容差收到 2 就不該命中——用獨立的 MRA_BENCHMARK_DIR，
# 不要動到上面主要 fixture。省略 --tolerance 時的結果要跟明講 --tolerance 5
# 逐位元組相同，才能釘住「brief 講的預設值就是 5」，不是恰好也 >=3 的別的數。
TOL_DIR="$TMP/bench-tol"
mkdir -p "$TOL_DIR" "$TMP/bin-tol"
cat > "$TOL_DIR/candidates.json" <<'J'
[
 {"repo":"acme/rails-app-1","pr":8501,"merged_at":"2026-08-01T00:00:00Z","fix_commits":[],
  "confirmed":true,
  "expected_findings":[{"path":"app/t.rb","line":50,"severity":"HIGH","note":"t"}]}
]
J
cat > "$TMP/bin-tol/mra" <<'SHIM'
#!/usr/bin/env bash
printf '%s' '{"status":"CHANGES_REQUESTED","summary":"x","comments":[
 {"path":"app/t.rb","line":53,"body":"x","severity":"HIGH"}]}'
SHIM
chmod +x "$TMP/bin-tol/mra"
PATH="$TMP/bin-tol:$PATH" MRA_BENCHMARK_DIR="$TOL_DIR" \
  bash "$S" --label notol >/dev/null 2>&1
PATH="$TMP/bin-tol:$PATH" MRA_BENCHMARK_DIR="$TOL_DIR" \
  bash "$S" --label tol5 --tolerance 5 >/dev/null 2>&1
PATH="$TMP/bin-tol:$PATH" MRA_BENCHMARK_DIR="$TOL_DIR" \
  bash "$S" --label tol2 --tolerance 2 >/dev/null 2>&1

eq "不給 --tolerance 時距離 3 的 comment 命中(漏抓 0)" "0" \
  "$(jq -r '.missed' "$TOL_DIR/runs/notol/summary.json")"
eq "--tolerance 2 時距離 3 的 comment 不命中(漏抓 1，方向對)" "1" \
  "$(jq -r '.missed' "$TOL_DIR/runs/tol2/summary.json")"
notol_body="$(jq -S 'del(.label)' "$TOL_DIR/runs/notol/summary.json")"
tol5_body="$(jq -S 'del(.label)' "$TOL_DIR/runs/tol5/summary.json")"
eq "省略 --tolerance 跟明講 --tolerance 5 結果相同(預設值真的是 5)" \
  "$notol_body" "$tol5_body"

# --- status=="COMMENT" 只可能是 REVIEW_INCOMPLETE，不能被當成「零發現」計
# 入彙總：inline schema 只允許 APPROVED/CHANGES_REQUESTED(見 lib/review.sh)，
# COMMENT 是 _review_singlepass_body 在 raw 為空或找不到完成 sentinel 時的
# 專屬產物。混進彙總的話，一次沒跑完的 review 會被當成「零發現」，那個 PR
# 的 expected finding 全數算成漏抓。用獨立的 MRA_BENCHMARK_DIR，不要動到
# 上面主要 fixture 的 candidates.json。
#
# 9201=incomplete(status=COMMENT，expected 1 筆，完全不該計入彙總)
# 9202=正常(status=CHANGES_REQUESTED，命中 1 筆)
# 9203=failed(mra 本身 exit 1)
INC_DIR="$TMP/bench-incomplete"
mkdir -p "$INC_DIR" "$TMP/bin-incomplete"
cat > "$INC_DIR/candidates.json" <<'J'
[
 {"repo":"acme/rails-app-1","pr":9201,"merged_at":"2026-08-01T00:00:00Z","fix_commits":[],
  "confirmed":true,
  "expected_findings":[{"path":"app/a.rb","line":10,"severity":"HIGH","note":"a"}]},
 {"repo":"acme/rails-app-1","pr":9202,"merged_at":"2026-08-02T00:00:00Z","fix_commits":[],
  "confirmed":true,
  "expected_findings":[{"path":"app/b.rb","line":20,"severity":"HIGH","note":"b"}]},
 {"repo":"acme/rails-app-1","pr":9203,"merged_at":"2026-08-03T00:00:00Z","fix_commits":[],
  "confirmed":true,
  "expected_findings":[{"path":"app/c.rb","line":30,"severity":"HIGH","note":"c"}]}
]
J
cat > "$TMP/bin-incomplete/mra" <<'SHIM'
#!/usr/bin/env bash
case "$*" in
  *"--pr 9201"*)
    echo "[review] running claude (sonnet)..." >&2
    echo "codex transient failure (ec=142)" >&2
    printf '%s' '{"status":"COMMENT","comments":[]}' ;;
  *"--pr 9202"*)
    printf '%s' '{"status":"CHANGES_REQUESTED","summary":"x","comments":[
     {"path":"app/b.rb","line":20,"body":"x","severity":"HIGH"}]}' ;;
  *"--pr 9203"*)
    echo "some diagnostic noise before dying" >&2
    exit 1 ;;
  *)
    echo "unexpected mra invocation: $*" >&2; exit 1 ;;
esac
SHIM
chmod +x "$TMP/bin-incomplete/mra"

out_inc="$(PATH="$TMP/bin-incomplete:$PATH" MRA_BENCHMARK_DIR="$INC_DIR" \
  bash "$S" --label incomplete-test 2>"$TMP/incomplete.err")"
rc_inc=$?
eq "1 筆 incomplete + 1 筆 failed + 1 筆正常時退出碼仍是 0" "0" "$rc_inc"
has "終端機摘要行也印出 incomplete／failed 筆數" "$out_inc" "incomplete=1 failed=1"

INC_RUN="$INC_DIR/runs/incomplete-test"
S_INC="$INC_RUN/summary.json"

eq "incomplete 的 PR 不計入 expected_total(只有 9202 的 1 筆)" "1" \
  "$(jq -r '.expected_total' "$S_INC")"
eq "prs 只算成功納入彙總的 1 筆(9202)" "1" "$(jq -r '.prs' "$S_INC")"
eq "incomplete_count 是 1" "1" "$(jq -r '.incomplete_count' "$S_INC")"
eq "incomplete_prs 清單裡是 acme/rails-app-1#9201" "acme/rails-app-1#9201" \
  "$(jq -r '.incomplete_prs[0]' "$S_INC")"
eq "failed_count 是 1(9203)" "1" "$(jq -r '.failed_count' "$S_INC")"
eq "failed_prs 清單裡是 acme/rails-app-1#9203" "acme/rails-app-1#9203" \
  "$(jq -r '.failed_prs[0]' "$S_INC")"

err_inc_text="$(cat "$TMP/incomplete.err")"
has "stderr 印出 REVIEW_INCOMPLETE" "$err_inc_text" "REVIEW_INCOMPLETE"
has "REVIEW_INCOMPLETE 訊息指名 acme/rails-app-1#9201" "$err_inc_text" "acme/rails-app-1#9201"
has "REVIEW_INCOMPLETE 訊息裡有 status=COMMENT 的字樣" "$err_inc_text" "status=COMMENT"

if [[ -e "$INC_RUN/acme__rails-app-1__9201.json" ]]; then
  fail "incomplete(9201)的輸出檔沒有被刪掉，下次續跑會被 -s 誤判成已完成而跳過"
else
  ok "incomplete(9201)的輸出檔有被刪掉(下次續跑才會真的重跑)"
fi

ERR_9201="$INC_RUN/acme__rails-app-1__9201.err"
if [[ -s "$ERR_9201" ]]; then
  ok "9201 的 .err 檔有寫出診斷內容"
else
  fail ".err 檔是空的或不存在：$ERR_9201"
fi
has ".err 檔內容包含真正的診斷訊息(codex transient failure)" \
  "$(cat "$ERR_9201")" "codex transient failure"
has "REVIEW_INCOMPLETE 訊息指出 .err 檔路徑" "$err_inc_text" "$ERR_9201"

ERR_9203="$INC_RUN/acme__rails-app-1__9203.err"
if [[ -s "$ERR_9203" ]]; then
  ok "9203(failed)的 .err 檔有寫出診斷內容"
else
  fail ".err 檔是空的或不存在：$ERR_9203"
fi
has "REVIEW_FAILED(9203)訊息指出 .err 檔路徑" "$err_inc_text" "$ERR_9203"

# --- 續跑時 incomplete 的 PR 真的會被重跑，不會被 -s 卡住而永遠跳過 --------
cat > "$TMP/bin-incomplete/mra" <<'SHIM'
#!/usr/bin/env bash
case "$*" in
  *"--pr 9201"*)
    printf '%s' '{"status":"CHANGES_REQUESTED","summary":"x","comments":[
     {"path":"app/a.rb","line":10,"body":"x","severity":"HIGH"}]}' ;;
  *"--pr 9202"*)
    printf '%s' '{"status":"CHANGES_REQUESTED","summary":"x","comments":[
     {"path":"app/b.rb","line":20,"body":"x","severity":"HIGH"}]}' ;;
  *"--pr 9203"*)
    printf '%s' '{"status":"APPROVED","summary":"x","comments":[]}' ;;
  *)
    echo "unexpected mra invocation: $*" >&2; exit 1 ;;
esac
SHIM
chmod +x "$TMP/bin-incomplete/mra"
PATH="$TMP/bin-incomplete:$PATH" MRA_BENCHMARK_DIR="$INC_DIR" \
  bash "$S" --label incomplete-test >/dev/null 2>&1
eq "續跑(同一個 label)後 9201 真的重跑成功，prs 變成 3" "3" \
  "$(jq -r '.prs' "$S_INC")"
eq "續跑後 incomplete_count 歸零(9201 這次跑完了)" "0" \
  "$(jq -r '.incomplete_count' "$S_INC")"

# --- 沒有任何 confirmed=true 時要明講，不要輸出空的 summary 假裝跑過 -----
jq 'map(.confirmed = false)' "$C" > "$TMP/c.json"
mv "$TMP/c.json" "$C"
bash "$S" --label empty >"$TMP/empty.out" 2>"$TMP/empty.err"
rc_empty=$?
eq "無 confirmed 時退出非 0" "1" "$rc_empty"
has "無 confirmed 時印出 NO_CONFIRMED 訊息" "$(cat "$TMP/empty.err")" "NO_CONFIRMED"
if [[ -e "$MRA_BENCHMARK_DIR/runs/empty/summary.json" ]]; then
  fail "無 confirmed 時不該輸出 summary.json"
else
  ok "無 confirmed 時沒有輸出假的 summary.json"
fi

echo "---"; echo "Passed: $pass"; echo "Failed: $errors"
exit $((errors > 0 ? 1 : 0))
