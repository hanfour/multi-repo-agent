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
# 自家 repo 的真實清單放在版控外，跑這支測試的機器上可能存在。不 pin 的話
# 分層注入那幾條會拿使用者真正的清單去查層，acme/* 查不到就 REPO_LAYER_UNKNOWN
# 擋在開跑前，斷言在程式沒問題的時候轉紅。
export MRA_CORPUS_INTERNAL_TARGETS="$TMP/no-such-targets.tsv"
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

# --- summary.json 要記執行條件，不是只記三個指標：兩份 summary 看起來可
# 比，實際上可能是不同 tolerance／設定算出來的，沒有這些欄位完全看不出來 --
eq "tolerance 記的是這次真的用的值(沒給 --tolerance，預設 5)" "5" \
  "$(jq -r '.tolerance' "$S1")"
eq "candidates_confirmed 是 5(8101-8105 五筆 confirmed=true，不是只算成功納入彙總的 prs)" \
  "5" "$(jq -r '.candidates_confirmed' "$S1")"
eq "candidates_sha 是 candidates.json 內容的 sha256 前 16 碼" \
  "$(shasum -a 256 "$C" | cut -c1-16)" "$(jq -r '.candidates_sha' "$S1")"
eq "candidates_sha 長度是 16 碼(不是完整 64 碼的 sha256)" "16" \
  "$(jq -r '.candidates_sha | length' "$S1")"

# --- model／provider／reasoning_effort／review_mode／max_turns／
# synth_max_turns／worktree_isolated／mra_config_path：這支測試的 mra
# shim 是裸的假指令，不認得 MRA_BACKTEST_COND_FILE，run-backtest.sh 讀不到
# 執行條件回報檔。這八個欄位這時候要一律是 null，conditions_source 要是
# "unavailable"，絕對不能悄悄退回讀共用 $MRA_DIR/config.json 的值(那正是
# 更早一輪要修掉的東西：記錯的值比沒有欄位更糟)。
#
# 直接斷言型別，不繞道 jq -e。舊寫法的註解說辨別力來自 -e，那是錯的：-e 只
# 影響退出碼，而退出碼在 command substitution 裡被丟掉了。真正在分辨 JSON
# null 與字串 "null" 的是「沒有加 -r」——字串會印成帶引號的 "null"。那個機制
# 有效但很隱晦，而且被一句錯的註解蓋住。`| type` 把判準直接寫出來，欄位缺席
# 時回 "null" 以外的值也一樣抓得到。
for _cond_key in model provider reasoning_effort review_mode max_turns \
                 synth_max_turns worktree_isolated mra_config_path; do
  eq "沒有 cond 檔可讀時 ${_cond_key} 的型別是 null" "null" \
    "$(jq -r --arg k "$_cond_key" '.[$k] | type' "$S1")"
done
eq "conditions_source 記成 unavailable" "unavailable" "$(jq -r '.conditions_source' "$S1")"

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
eq "tol5 這次跑出來的 tolerance 欄位記的是 5" "5" \
  "$(jq -r '.tolerance' "$TOL_DIR/runs/tol5/summary.json")"

# --- 這次改動的核心目的：同一份「已經跑完」的輸出，換 --tolerance 重跑
# 同一個 label，summary 的 tolerance 欄位要跟著變。只驗欄位存在不夠，這裡
# 拿掉 mra 這個指令本身(不是清快取)，如果 rerun 因為某個地方又呼叫了一次
# review，會直接因為找不到 mra 指令而整個失敗；能成功印證的是這次改動
# 完全靠 -s 判定重用既有輸出檔，沒有真的再叫一次 review(coordinator 說的
# 「成本接近零」)。同一個 label(tol5)重跑，只改 --tolerance，其餘設定完全
# 不變，藉此單獨隔離出「只有 tolerance 欄位該變、其他執行條件欄位不該變」
# 這件事。 --------------------------------------------------------------
rm -f "$TMP/bin-tol/mra"
PATH="$TMP/bin-tol:$PATH" MRA_BENCHMARK_DIR="$TOL_DIR" \
  bash "$S" --label tol5 --tolerance 2 >"$TMP/tol5-rerun.out" 2>"$TMP/tol5-rerun.err"
rc_tol5_rerun=$?
eq "同一個 label 換 tolerance 重跑退出碼仍是 0(靠快取，沒有真的再叫 mra)" \
  "0" "$rc_tol5_rerun"
eq "重跑後 tolerance 欄位變成 2(不是還停在第一次跑的 5)" "2" \
  "$(jq -r '.tolerance' "$TOL_DIR/runs/tol5/summary.json")"
eq "重跑後 missed 也跟著 tolerance=2 重算(變成 1，不是還停在 tolerance=5 算出的 0)" \
  "1" "$(jq -r '.missed' "$TOL_DIR/runs/tol5/summary.json")"
eq "重跑後 conditions_source 這種跟 tolerance 無關的欄位維持不變" \
  "unavailable" "$(jq -r '.conditions_source' "$TOL_DIR/runs/tol5/summary.json")"

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

# 這個 fixture 只有 3 筆 confirmed、成功納入彙總的只有 1 筆(9202)，比例
# 1/3 遠低於覆蓋率下限的預設門檻 0.8。這支測試驗的是「incomplete／failed
# 的 PR 有沒有被正確排除」這件事本身，不是覆蓋率門檻的行為(那條在
# tests/test_run_backtest_coverage.sh 另外測)，用
# MRA_BACKTEST_MIN_COVERAGE=0 停用門檻，這個 fixture 才不用為了配合門檻
# 硬湊更多 confirmed 筆數，模糊掉它原本要驗的事。
out_inc="$(PATH="$TMP/bin-incomplete:$PATH" MRA_BENCHMARK_DIR="$INC_DIR" \
  MRA_BACKTEST_MIN_COVERAGE=0 bash "$S" --label incomplete-test 2>"$TMP/incomplete.err")"
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

# --- model／provider／reasoning_effort／review_mode／max_turns／
# synth_max_turns／worktree_isolated／mra_config_path：這八個不是
# run-backtest.sh 自己知道的東西，run-backtest.sh 只負責讀 $MRA_CMD 透過
# MRA_BACKTEST_COND_FILE 回報回來的內容，不自己猜、不 fallback 去讀共用
# config.json(見這次改動的由來：更早一版猜過，猜錯了，記錯的值比沒有
# 欄位更糟)。這裡用一個會回報 cond 檔的 stub 模擬真正的 adapter，真正
# adapter 自己寫 cond 檔那段邏輯由 tests/test_backtest_adapter.sh 驗。
# 欄位原本叫 codex_model，改名成 model、加一個 provider 欄位；
# agent_max_turns 欄位後來也發現同一個問題(只影響 debate 路徑的 round-1
# agent，standard／personas 兩條回測會走到的路徑都不受它控制)，改名成
# max_turns，另外加一個 synth_max_turns(personas 模式 synthesize 這一步
# 的上限，standard 是 null)。 -----------------------------------------------
COND_DIR="$TMP/bench-cond"
mkdir -p "$COND_DIR" "$TMP/bin-cond"
cat > "$COND_DIR/candidates.json" <<'J'
[
 {"repo":"acme/rails-app-1","pr":8601,"merged_at":"2026-08-01T00:00:00Z","fix_commits":[],
  "confirmed":true,"expected_findings":[{"path":"app/x.rb","line":10,"severity":"HIGH","note":"讓基準集不是空的"}]}
]
J
cat > "$TMP/bin-cond/mra" <<'SHIM'
#!/usr/bin/env bash
if [[ -n "${MRA_BACKTEST_COND_FILE:-}" ]]; then
  jq -n '{model:"gpt-9.9-test",provider:"codex",reasoning_effort:"medium",
          review_mode:"standard",max_turns:99,synth_max_turns:null,
          worktree_isolated:true,mra_config_path:"/fake/derived-config.json"}' \
    > "$MRA_BACKTEST_COND_FILE"
fi
printf '%s' '{"status":"APPROVED","summary":"x","comments":[]}'
SHIM
chmod +x "$TMP/bin-cond/mra"
PATH="$TMP/bin-cond:$PATH" MRA_BENCHMARK_DIR="$COND_DIR" \
  bash "$S" --label condtest >/dev/null 2>&1
S_COND="$COND_DIR/runs/condtest/summary.json"
eq "cond 檔讀得到時，model 是 adapter 實際回報的值" "gpt-9.9-test" \
  "$(jq -r '.model' "$S_COND")"
eq "cond 檔讀得到時，provider 是 adapter 實際回報的值" "codex" \
  "$(jq -r '.provider' "$S_COND")"
eq "cond 檔讀得到時，reasoning_effort 是 adapter 實際回報的值" "medium" \
  "$(jq -r '.reasoning_effort' "$S_COND")"
eq "cond 檔讀得到時，review_mode 是 adapter 實際回報的值" "standard" \
  "$(jq -r '.review_mode' "$S_COND")"
eq "cond 檔讀得到時，max_turns 是 adapter 實際回報的值(欄位已從 agent_max_turns 改名)" "99" \
  "$(jq -r '.max_turns' "$S_COND")"
eq "standard 模式沒有 synthesize 這一步，synth_max_turns 正確傳遞成 JSON null" "null" \
  "$(jq -e '.synth_max_turns' "$S_COND")"
eq "cond 檔讀得到時，worktree_isolated 是 adapter 自己回報的 true" "true" \
  "$(jq -r '.worktree_isolated' "$S_COND")"
eq "cond 檔讀得到時，mra_config_path 是 adapter 實際回報的路徑" \
  "/fake/derived-config.json" "$(jq -r '.mra_config_path' "$S_COND")"
eq "cond 檔讀得到時，conditions_source 是 adapter" "adapter" \
  "$(jq -r '.conditions_source' "$S_COND")"

# 換一組不同的值、換個新 label 重跑(避免跟快取／同 label 重跑的情境混在
# 一起)，驗證真的是「讀 stub 這次實際回報的內容」，不是釘死在測試裡的一組
# 固定字面值湊巧對上。
cat > "$TMP/bin-cond/mra" <<'SHIM'
#!/usr/bin/env bash
if [[ -n "${MRA_BACKTEST_COND_FILE:-}" ]]; then
  jq -n '{model:"gpt-different-model",provider:"codex",reasoning_effort:"low",
          review_mode:"personas",max_turns:7,synth_max_turns:3,
          worktree_isolated:true,mra_config_path:"/fake/other-config.json"}' \
    > "$MRA_BACKTEST_COND_FILE"
fi
printf '%s' '{"status":"APPROVED","summary":"x","comments":[]}'
SHIM
chmod +x "$TMP/bin-cond/mra"
PATH="$TMP/bin-cond:$PATH" MRA_BENCHMARK_DIR="$COND_DIR" \
  bash "$S" --label condtest2 >/dev/null 2>&1
eq "stub 回報的內容換了，model 也跟著變(不是釘死的值)" "gpt-different-model" \
  "$(jq -r '.model' "$COND_DIR/runs/condtest2/summary.json")"
eq "stub 回報的內容換了，max_turns 也跟著變" "7" \
  "$(jq -r '.max_turns' "$COND_DIR/runs/condtest2/summary.json")"
eq "stub 回報的內容換了，synth_max_turns 也跟著變" "3" \
  "$(jq -r '.synth_max_turns' "$COND_DIR/runs/condtest2/summary.json")"

# --- personas 模式的 cond 檔：provider／model 是 claude／sonnet，
# reasoning_effort 是 JSON null。這裡驗的是 run-backtest.sh 自己讀 cond
# 檔的機制正確傳遞 null(不是把它讀成字串"null"或空字串)；claude 沒有
# reasoning effort 這個概念，這是真正 adapter 在 personas 模式下會回報的
# 形狀，adapter 自己怎麼產生這個 null 由 test_backtest_adapter.sh 驗。
cat > "$TMP/bin-cond/mra" <<'SHIM'
#!/usr/bin/env bash
if [[ -n "${MRA_BACKTEST_COND_FILE:-}" ]]; then
  jq -n '{model:"sonnet",provider:"claude",reasoning_effort:null,
          review_mode:"personas",max_turns:8,synth_max_turns:8,
          worktree_isolated:true,mra_config_path:"/fake/personas-config.json"}' \
    > "$MRA_BACKTEST_COND_FILE"
fi
printf '%s' '{"status":"APPROVED","summary":"x","comments":[]}'
SHIM
chmod +x "$TMP/bin-cond/mra"
PATH="$TMP/bin-cond:$PATH" MRA_BENCHMARK_DIR="$COND_DIR" \
  bash "$S" --label condtest3 >/dev/null 2>&1
S_COND3="$COND_DIR/runs/condtest3/summary.json"
eq "personas cond 檔讀得到時，provider 是 claude" "claude" "$(jq -r '.provider' "$S_COND3")"
eq "personas cond 檔讀得到時，model 是 sonnet" "sonnet" "$(jq -r '.model' "$S_COND3")"
eq "personas cond 檔讀得到時，reasoning_effort 正確傳遞成 JSON null" "null" \
  "$(jq -e '.reasoning_effort' "$S_COND3")"
eq "personas cond 檔讀得到時，max_turns 是 adapter 實際回報的值(不是舊的 agent_max_turns=40)" \
  "8" "$(jq -r '.max_turns' "$S_COND3")"
eq "personas cond 檔讀得到時，synth_max_turns 是數字(personas 模式一定有 synthesize 這一步)" \
  "8" "$(jq -r '.synth_max_turns' "$S_COND3")"

# --- 沒有 cond 檔可讀時，絕對不能悄悄退回共用 $MRA_DIR/config.json 的值 ---
# 這是上一輪修正的核心，這一輪欄位改名後要繼續守住：用一支「不知道
# MRA_BACKTEST_COND_FILE 這個 env」的裸 stub，即使共用 config.json 裡有
# 明確的 codex model 值，summary 裡的 model 也必須是 null，不能是那個值。
# 記錯的值比沒有欄位更糟：沒有欄位人會知道要去別處查，記了共用
# config.json 的值，階段四會誤以為那就是這次實際用的 model。
UNAVAIL_DIR="$TMP/bench-cond-unavail"
mkdir -p "$UNAVAIL_DIR" "$TMP/bin-cond-unavail"
cat > "$UNAVAIL_DIR/candidates.json" <<'J'
[
 {"repo":"acme/rails-app-1","pr":8602,"merged_at":"2026-08-01T00:00:00Z","fix_commits":[],
  "confirmed":true,
  "expected_findings":[{"path":"app/x.rb","line":10,"severity":"HIGH","note":"讓基準集不是空的"}]}
]
J
cat > "$TMP/bin-cond-unavail/mra" <<'SHIM'
#!/usr/bin/env bash
# 故意完全不理會 MRA_BACKTEST_COND_FILE，模擬「呼叫的是裸 bin/mra.sh 或
# 測試用的 stub，沒有 adapter 那層」的情境。
printf '%s' '{"status":"APPROVED","summary":"x","comments":[]}'
SHIM
chmod +x "$TMP/bin-cond-unavail/mra"
PATH="$TMP/bin-cond-unavail:$PATH" MRA_BENCHMARK_DIR="$UNAVAIL_DIR" \
  bash "$S" --label unavailtest >/dev/null 2>&1
S_UNAVAIL="$UNAVAIL_DIR/runs/unavailtest/summary.json"

MRA_DIR_FOR_TEST="$(cd "$(dirname "$S")/.." && pwd)"
real_shared_codex_model="$(jq -r '.review.models.codex // empty' "$MRA_DIR_FOR_TEST/config.json")"
if [[ -n "$real_shared_codex_model" ]]; then
  ok "測試前提成立：共用 config.json 裡真的有填 codex model(${real_shared_codex_model})"
else
  fail "測試前提不成立：共用 config.json 沒有 .review.models.codex，下面測不出東西"
fi
eq "沒有 cond 檔時 model 是 null，不是偷偷退回共用 config.json 的值" \
  "null" "$(jq -r '.model' "$S_UNAVAIL")"
lacks "summary.json 裡不該出現共用 config.json 那個 codex model 值" \
  "$(jq -c . "$S_UNAVAIL")" "$real_shared_codex_model"
eq "沒有 cond 檔時 conditions_source 是 unavailable" "unavailable" \
  "$(jq -r '.conditions_source' "$S_UNAVAIL")"

# --- candidates_sha：候選集內容變了，這個值要跟著變，不是釘死的值或只看
# 檔名／路徑。這是這次最重要的欄位：階段四若重建過候選集，分母就不同，這
# 個欄位是唯一能看出來的線索 -------------------------------------------------
SHA_DIR="$TMP/bench-sha"
mkdir -p "$SHA_DIR" "$TMP/bin-sha"
cat > "$SHA_DIR/candidates.json" <<'J'
[
 {"repo":"acme/rails-app-1","pr":8801,"merged_at":"2026-08-01T00:00:00Z","fix_commits":[],
  "confirmed":true,"expected_findings":[{"path":"app/x.rb","line":10,"severity":"HIGH","note":"讓基準集不是空的"}]}
]
J
cat > "$TMP/bin-sha/mra" <<'SHIM'
#!/usr/bin/env bash
printf '%s' '{"status":"APPROVED","summary":"x","comments":[]}'
SHIM
chmod +x "$TMP/bin-sha/mra"
PATH="$TMP/bin-sha:$PATH" MRA_BENCHMARK_DIR="$SHA_DIR" \
  bash "$S" --label shatest1 >/dev/null 2>&1
sha_before="$(jq -r '.candidates_sha' "$SHA_DIR/runs/shatest1/summary.json")"

# 改候選集內容(加一筆)，換個 label 重跑：這裡要驗的是「候選集內容不同」
# 這件事本身，故意不用同一個 label，避免跟上面 tolerance 那條「同 label
# 重跑用快取」的情境混在一起。
jq '. + [{"repo":"acme/rails-app-1","pr":8802,"merged_at":"2026-08-02T00:00:00Z",
          "fix_commits":[],"confirmed":true,"expected_findings":[]}]' \
  "$SHA_DIR/candidates.json" > "$SHA_DIR/candidates.json.new"
mv "$SHA_DIR/candidates.json.new" "$SHA_DIR/candidates.json"
PATH="$TMP/bin-sha:$PATH" MRA_BENCHMARK_DIR="$SHA_DIR" \
  bash "$S" --label shatest2 >/dev/null 2>&1
sha_after="$(jq -r '.candidates_sha' "$SHA_DIR/runs/shatest2/summary.json")"

if [[ "$sha_before" != "$sha_after" ]]; then
  ok "候選集內容改變後，candidates_sha 跟著變(不是釘死的值)"
else
  fail "候選集內容改變了，candidates_sha 卻沒變：$sha_before"
fi
eq "candidates_confirmed 也跟著候選集內容變化(1 筆變 2 筆)" "2" \
  "$(jq -r '.candidates_confirmed' "$SHA_DIR/runs/shatest2/summary.json")"

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

# --- 形狀不合法的輸出檔也要刪掉，續跑才會真的重跑 -------------------------
# 跟 REVIEW_INCOMPLETE 同一個道理，但來源不同：形狀不合法最常見的成因是回測
# 被外力中止（額度耗盡、Ctrl-C）時 `> "$f"` 已建檔卻還沒寫完，而續跑正是這種
# 中止之後才會做的事。不刪的話，`-s` 會把這個半成品判成「已經有結果」而跳過，
# 一次可以自動修復的中斷就變成一個要人工發現的永久缺口。
#
# 9301 的第一輪回傳合法 JSON 但沒有 comments 欄位（模擬寫到一半被截斷的檔案
# 仍是合法 JSON 的情況），第二輪回傳正常結果，用來驗續跑真的會重跑。
SHP_DIR="$TMP/bench-shape"
mkdir -p "$SHP_DIR" "$TMP/bin-shape"
cat > "$SHP_DIR/candidates.json" <<'J'
[
 {"repo":"acme/rails-app-1","pr":9301,"merged_at":"2026-08-01T00:00:00Z","fix_commits":[],
  "confirmed":true,
  "expected_findings":[{"path":"app/a.rb","line":10,"severity":"HIGH","note":"a"}]}
]
J
cat > "$TMP/bin-shape/mra" <<'SHIM'
#!/usr/bin/env bash
printf '%s' '{"status":"CHANGES_REQUESTED","summary":"截斷"}'
SHIM
chmod +x "$TMP/bin-shape/mra"

PATH="$TMP/bin-shape:$PATH" MRA_BENCHMARK_DIR="$SHP_DIR" MRA_BACKTEST_MIN_COVERAGE=0 \
  bash "$S" --label shape-test >/dev/null 2>"$TMP/shape.err"
has "stderr 印出 REVIEW_SHAPE_INVALID" "$(cat "$TMP/shape.err")" "REVIEW_SHAPE_INVALID"
if [[ -e "$SHP_DIR/runs/shape-test/acme__rails-app-1__9301.json" ]]; then
  fail "形狀不合法的輸出檔沒有被刪掉，下次續跑會被 -s 誤判成已完成而跳過"
else
  ok "形狀不合法的輸出檔有被刪掉"
fi

cat > "$TMP/bin-shape/mra" <<'SHIM'
#!/usr/bin/env bash
printf '%s' '{"status":"CHANGES_REQUESTED","summary":"x","comments":[
 {"path":"app/a.rb","line":10,"body":"x","severity":"HIGH"}]}'
SHIM
PATH="$TMP/bin-shape:$PATH" MRA_BENCHMARK_DIR="$SHP_DIR" MRA_BACKTEST_MIN_COVERAGE=0 \
  bash "$S" --label shape-test >/dev/null 2>&1
eq "續跑時形狀不合法的 PR 真的重跑並納入彙總" "1" \
  "$(jq -r '.prs' "$SHP_DIR/runs/shape-test/summary.json")"

# --- summary 要同時報行號漏抓與檔案層級漏抓 -------------------------------
# 只報行號容差會把「沒看到那個檔案」與「看到了但錨點落在幾十行外」讀成同一件
# 事，而兩者的處置完全不同。
#
# 這個 fixture 的重點在 9401 與 9402 都改到同名的 app/shared.rb：9401 對它
# 一句話都沒說，9402 對它講了但落在 500 行外。逐 PR 算的話 9401 算 1 條檔案
# 層級漏抓；若哪天有人把它改成對攤平後的 comment 陣列算一次，9401 的 expected
# 會配到 9402 的 comment，file_missed 會變成 0。這裡把正確值釘住。
FM_DIR="$TMP/bench-filemiss"
mkdir -p "$FM_DIR" "$TMP/bin-filemiss"
cat > "$FM_DIR/candidates.json" <<'J'
[
 {"repo":"acme/rails-app-1","pr":9401,"merged_at":"2026-08-01T00:00:00Z","fix_commits":[],
  "confirmed":true,
  "expected_findings":[{"path":"app/shared.rb","line":10,"severity":"HIGH","note":"9401 完全沒講"}]},
 {"repo":"acme/rails-app-1","pr":9402,"merged_at":"2026-08-02T00:00:00Z","fix_commits":[],
  "confirmed":true,
  "expected_findings":[{"path":"app/shared.rb","line":20,"severity":"HIGH","note":"9402 同檔有講但很遠"}]}
]
J
cat > "$TMP/bin-filemiss/mra" <<'SHIM'
#!/usr/bin/env bash
case "$*" in
  *"--pr 9401"*)
    printf '%s' '{"status":"CHANGES_REQUESTED","summary":"x","comments":[
     {"path":"app/other.rb","line":10,"body":"講的是別的檔案","severity":"HIGH"}]}' ;;
  *"--pr 9402"*)
    printf '%s' '{"status":"CHANGES_REQUESTED","summary":"x","comments":[
     {"path":"app/shared.rb","line":520,"body":"同檔但離 500 行","severity":"HIGH"}]}' ;;
  *) echo "unexpected: $*" >&2; exit 1 ;;
esac
SHIM
chmod +x "$TMP/bin-filemiss/mra"

PATH="$TMP/bin-filemiss:$PATH" MRA_BENCHMARK_DIR="$FM_DIR" MRA_BACKTEST_MIN_COVERAGE=0 \
  bash "$S" --label filemiss-test >"$TMP/fm.out" 2>/dev/null
S_FM="$FM_DIR/runs/filemiss-test/summary.json"
eq "兩條 expected 在 ±5 之下都算漏抓" "2" "$(jq -r '.missed' "$S_FM")"
eq "檔案層級只有 9401 算漏（9402 同檔有講）" "1" "$(jq -r '.file_missed' "$S_FM")"
eq "file_miss_rate 是 1/2" "0.5" "$(jq -r '.file_miss_rate' "$S_FM")"
eq "anchor_drift 是 missed 減 file_missed" "1" "$(jq -r '.anchor_drift' "$S_FM")"
has "終端機摘要同時印出兩個指標" "$(cat "$TMP/fm.out")" "同檔完全沒講"
has "終端機摘要印出錨點漂移" "$(cat "$TMP/fm.out")" "錨點漂移"

# --- --recompute 只重算，不跑 review、不覆寫 .err -------------------------
# 換個容差再算一次時，不該連帶重跑失敗的 PR。實測過一次代價：兩筆 PR 原本的
# 失敗原因是 synthesize 輪數用盡，容差重算時 OAuth 剛好過期，.err 全被換成
# OAuth 錯誤，原本的診斷證據消失。
RC_DIR="$TMP/bench-recompute"
mkdir -p "$RC_DIR" "$TMP/bin-recompute"
cat > "$RC_DIR/candidates.json" <<'J'
[
 {"repo":"acme/rails-app-1","pr":9501,"merged_at":"2026-08-01T00:00:00Z","fix_commits":[],
  "confirmed":true,
  "expected_findings":[{"path":"app/a.rb","line":10,"severity":"HIGH","note":"跑得成"}]},
 {"repo":"acme/rails-app-1","pr":9502,"merged_at":"2026-08-02T00:00:00Z","fix_commits":[],
  "confirmed":true,
  "expected_findings":[{"path":"app/b.rb","line":20,"severity":"HIGH","note":"跑不成"}]}
]
J
# 第一輪：9501 成功、9502 失敗並留下一段可辨識的診斷訊息
cat > "$TMP/bin-recompute/mra" <<'SHIM'
#!/usr/bin/env bash
case "$*" in
  *"--pr 9501"*)
    printf '%s' '{"status":"CHANGES_REQUESTED","summary":"x","comments":[
     {"path":"app/a.rb","line":12,"body":"距離 2","severity":"HIGH"}]}' ;;
  *"--pr 9502"*)
    echo "ORIGINAL_FAILURE_REASON: synthesize 輪數用盡" >&2; exit 1 ;;
esac
SHIM
chmod +x "$TMP/bin-recompute/mra"
PATH="$TMP/bin-recompute:$PATH" MRA_BENCHMARK_DIR="$RC_DIR" MRA_BACKTEST_MIN_COVERAGE=0 \
  bash "$S" --label rc-test >/dev/null 2>&1
ERR_9502="$RC_DIR/runs/rc-test/acme__rails-app-1__9502.err"
has "第一輪留下原始的失敗原因" "$(cat "$ERR_9502" 2>/dev/null)" "ORIGINAL_FAILURE_REASON"

# 第二輪用 --recompute。把 mra 換成「一被呼叫就寫進 canary 檔並改寫 .err」的
# 版本：--recompute 若真的沒跑 review，canary 不會出現、.err 不會變。
cat > "$TMP/bin-recompute/mra" <<'SHIM'
#!/usr/bin/env bash
echo "CALLED $*" >> "$MRA_TEST_CANARY"
echo "OVERWRITTEN_BY_RECOMPUTE" >&2
exit 1
SHIM
CANARY="$TMP/recompute-canary"
: > "$CANARY"
PATH="$TMP/bin-recompute:$PATH" MRA_BENCHMARK_DIR="$RC_DIR" \
  MRA_BACKTEST_MIN_COVERAGE=0 MRA_TEST_CANARY="$CANARY" \
  bash "$S" --label rc-test --tolerance 15 --recompute >/dev/null 2>"$TMP/rc2.err"
eq "--recompute 完全沒呼叫過 mra" "0" "$(wc -l < "$CANARY" | tr -d ' ')"
has "第一輪的失敗原因沒有被覆寫" "$(cat "$ERR_9502" 2>/dev/null)" "ORIGINAL_FAILURE_REASON"
lacks ".err 沒有被重跑的訊息汙染" "$(cat "$ERR_9502" 2>/dev/null)" "OVERWRITTEN_BY_RECOMPUTE"
has "跑不成的 PR 印出 RECOMPUTE_SKIP" "$(cat "$TMP/rc2.err")" "RECOMPUTE_SKIP"
S_RC="$RC_DIR/runs/rc-test/summary.json"
eq "重算後容差確實換成 15" "15" "$(jq -r '.tolerance' "$S_RC")"
eq "只有跑得成的那筆計入彙總" "1" "$(jq -r '.prs' "$S_RC")"
eq "跑不成的那筆記成 failed" "1" "$(jq -r '.failed_count' "$S_RC")"

# --- 容差必須是非負數 -----------------------------------------------------
# 只驗「是合法 JSON」的話 null、-3、[]、{} 全部會過，而 null 與負值的後果是
# 每一條 expected 都不命中、漏抓率變成完美的 1.0（jq 的型別排序裡 null 小於
# 任何數字，`距離 <= null` 恆為 false）。那個 1.0 會原樣寫進 summary.json，
# 事後看不出它是垃圾。
# 只驗退出碼非 0 是不夠的：這個區塊跑在上面已經被改成全 confirmed=false 的
# 候選集上，NO_CONFIRMED 也會讓退出碼非 0。實測把容差驗證整段拿掉之後，
# 那種斷言仍然全綠。所以只驗訊息內容，那才分得出是哪一道擋的。
for bad_tol in null -3 '[]' '{}' abc '"5"'; do
  out_tol="$(bash "$S" --label tol-test --tolerance "$bad_tol" 2>&1)"
  has "容差 [$bad_tol] 被 TOLERANCE_INVALID 擋下來" "$out_tol" "TOLERANCE_INVALID"
  lacks "容差 [$bad_tol] 不是被別的檢查擋的" "$out_tol" "NO_CONFIRMED"
done
# 合法值不能被誤擋：0 是合法的（要求 comment 精準落在 expected 那一行）。
for good_tol in 0 5 15 2.5; do
  # 這裡不會真的跑成功（候選集在上面已被改成全 confirmed=false），只要確認
  # 擋下來的不是容差這一道即可。
  out_tol="$(bash "$S" --label tol-ok --tolerance "$good_tol" 2>&1)"
  lacks "合法容差 [$good_tol] 沒被誤擋" "$out_tol" "TOLERANCE_INVALID"
done

# --- MIN_COVERAGE 必須是 0 到 1 之間的數字 --------------------------------
# 只驗「是合法 JSON」的話 null 與 true 都會過，而 jq 的型別排序裡兩者都小於
# 任何數字，`$c < $m` 恆為 false，覆蓋率門檻被靜默關掉。那正是這道門檻要防的
# 東西：10 筆 confirmed 只跑成 1 筆也照樣輸出 summary、退出碼 0。
for bad_mc in null true '[]' abc 1.5 -0.1; do
  out_mc="$(MRA_BACKTEST_MIN_COVERAGE="$bad_mc" bash "$S" --label mc-test 2>&1)"
  has "MIN_COVERAGE [$bad_mc] 被擋下來" "$out_mc" "MIN_COVERAGE_INVALID"
done
for good_mc in 0 0.8 1; do
  out_mc="$(MRA_BACKTEST_MIN_COVERAGE="$good_mc" bash "$S" --label mc-ok 2>&1)"
  lacks "合法 MIN_COVERAGE [$good_mc] 沒被誤擋" "$out_mc" "MIN_COVERAGE_INVALID"
done

# --- 形狀不合法的 PR 要進 failed 計數，不能從三個計數器一起消失 ------------
# 不計數的話 prs + failed + incomplete 會小於 candidates_confirmed，而
# summary.json 裡沒有任何欄位解釋那個缺口。
SC_DIR="$TMP/bench-shapecount"
mkdir -p "$SC_DIR" "$TMP/bin-shapecount"
cat > "$SC_DIR/candidates.json" <<'J'
[
 {"repo":"acme/rails-app-1","pr":9601,"merged_at":"2026-08-01T00:00:00Z","fix_commits":[],
  "confirmed":true,
  "expected_findings":[{"path":"app/a.rb","line":10,"severity":"HIGH","note":"正常"}]},
 {"repo":"acme/rails-app-1","pr":9602,"merged_at":"2026-08-02T00:00:00Z","fix_commits":[],
  "confirmed":true,
  "expected_findings":[{"path":"app/b.rb","line":20,"severity":"HIGH","note":"形狀不合法"}]}
]
J
cat > "$TMP/bin-shapecount/mra" <<'SHIM'
#!/usr/bin/env bash
case "$*" in
  *"--pr 9601"*)
    printf '%s' '{"status":"CHANGES_REQUESTED","summary":"x","comments":[
     {"path":"app/a.rb","line":11,"body":"x","severity":"HIGH"}]}' ;;
  *"--pr 9602"*)
    printf '%s' '{"status":"CHANGES_REQUESTED","summary":"缺 comments 欄位"}' ;;
esac
SHIM
chmod +x "$TMP/bin-shapecount/mra"
out_sc="$(PATH="$TMP/bin-shapecount:$PATH" MRA_BENCHMARK_DIR="$SC_DIR" \
  MRA_BACKTEST_MIN_COVERAGE=0 bash "$S" --label sc-test 2>&1)"
S_SC="$SC_DIR/runs/sc-test/summary.json"
eq "形狀不合法的 PR 計入 failed" "1" "$(jq -r '.failed_count' "$S_SC")"
eq "failed_prs 清單指名是哪一個" "acme/rails-app-1#9602" "$(jq -r '.failed_prs[0]' "$S_SC")"
eq "prs + failed + incomplete 等於 candidates_confirmed" "2" \
  "$(jq -r '.prs + .failed_count + .incomplete_count' "$S_SC")"
has "SHAPE_INVALID 訊息指名 repo#pr" "$out_sc" "acme/rails-app-1#9602"

# --- --compare 要擋掉容差不同的兩份 summary -------------------------------
# 三個率全部由容差決定：同一批 review 輸出在 tol 5 與 tol 15 下可以是
# miss_rate 1.0 對 0.0，看起來像完勝。
CP_DIR="$TMP/bench-compare"
mkdir -p "$CP_DIR/runs/cp-a" "$CP_DIR/runs/cp-b"
echo '{"tolerance":5,"missed":1,"miss_rate":1.0,"expected_total":1,"comments_total":1,"unmatched":1,"unmatched_rate":1.0,"severity_agree":0,"severity_rate":0}' \
  > "$CP_DIR/runs/cp-a/summary.json"
echo '{"tolerance":15,"missed":0,"miss_rate":0.0,"expected_total":1,"comments_total":1,"unmatched":0,"unmatched_rate":0,"severity_agree":1,"severity_rate":1}' \
  > "$CP_DIR/runs/cp-b/summary.json"
out_cp="$(MRA_BENCHMARK_DIR="$CP_DIR" bash "$S" --compare cp-a cp-b 2>&1)"
rc_cp=$?
[ "$rc_cp" -ne 0 ] && ok "容差不同時 --compare 拒絕比較" || fail "應該擋下來"
has "訊息用 TOLERANCE_MISMATCH" "$out_cp" "TOLERANCE_MISMATCH"
# 容差相同時要正常比，而且要把容差本身印出來
cp "$CP_DIR/runs/cp-a/summary.json" "$CP_DIR/runs/cp-b/summary.json"
out_cp2="$(MRA_BENCHMARK_DIR="$CP_DIR" bash "$S" --compare cp-a cp-b 2>&1)"
has "容差相同時正常比較並印出容差" "$out_cp2" "tolerance"

# --- 兩道輸入驗證都要在跑任何 review 之前擋下來 ---------------------------
# 這支腳本一輪要跑幾小時、燒掉大量額度。一個打錯的 --tolerance 或
# MRA_BACKTEST_MIN_COVERAGE 如果等到全部跑完才報錯，那幾小時就白費了。
# 用 canary 檔驗證：擋下來的時候一次 review 都沒跑過。
EV_DIR="$TMP/bench-early"
mkdir -p "$EV_DIR" "$TMP/bin-early"
cat > "$EV_DIR/candidates.json" <<'J'
[{"repo":"acme/rails-app-1","pr":9701,"merged_at":"2026-08-01T00:00:00Z","fix_commits":[],
  "confirmed":true,
  "expected_findings":[{"path":"app/a.rb","line":10,"severity":"HIGH","note":"x"}]}]
J
cat > "$TMP/bin-early/mra" <<'SHIM'
#!/usr/bin/env bash
echo "CALLED" >> "$MRA_TEST_CANARY"
printf '%s' '{"status":"APPROVED","summary":"x","comments":[]}'
SHIM
chmod +x "$TMP/bin-early/mra"
EV_CANARY="$TMP/early-canary"

: > "$EV_CANARY"
PATH="$TMP/bin-early:$PATH" MRA_BENCHMARK_DIR="$EV_DIR" MRA_TEST_CANARY="$EV_CANARY" \
  bash "$S" --label ev-test --tolerance null >/dev/null 2>&1
eq "容差不合法時一次 review 都沒跑" "0" "$(wc -l < "$EV_CANARY" | tr -d ' ')"

: > "$EV_CANARY"
PATH="$TMP/bin-early:$PATH" MRA_BENCHMARK_DIR="$EV_DIR" MRA_TEST_CANARY="$EV_CANARY" \
  MRA_BACKTEST_MIN_COVERAGE=null bash "$S" --label ev-test >/dev/null 2>&1
eq "MIN_COVERAGE 不合法時一次 review 都沒跑" "0" "$(wc -l < "$EV_CANARY" | tr -d ' ')"

# 對照：兩個值都合法時真的會跑
: > "$EV_CANARY"
PATH="$TMP/bin-early:$PATH" MRA_BENCHMARK_DIR="$EV_DIR" MRA_TEST_CANARY="$EV_CANARY" \
  MRA_BACKTEST_MIN_COVERAGE=0 bash "$S" --label ev-ok --tolerance 5 >/dev/null 2>&1
eq "值都合法時 review 有跑" "1" "$(wc -l < "$EV_CANARY" | tr -d ' ')"

# --- --recompute 連跑兩次要得到一模一樣的結果 -----------------------------
# 它自己宣告「重算容差不該有副作用」。原本會刪掉形狀不合法與 incomplete 的
# 輸出檔，第二次跑時那些 PR 變成 RECOMPUTE_SKIP，失敗分類從 incomplete 變成
# failed —— 同一個指令跑兩次得到不同的 summary。
ID_DIR="$TMP/bench-idem"
mkdir -p "$ID_DIR" "$TMP/bin-idem"
cat > "$ID_DIR/candidates.json" <<'J'
[
 {"repo":"acme/rails-app-1","pr":9901,"merged_at":"2026-08-01T00:00:00Z","fix_commits":[],
  "confirmed":true,
  "expected_findings":[{"path":"app/a.rb","line":10,"severity":"HIGH","note":"正常"}]},
 {"repo":"acme/rails-app-1","pr":9902,"merged_at":"2026-08-02T00:00:00Z","fix_commits":[],
  "confirmed":true,
  "expected_findings":[{"path":"app/b.rb","line":20,"severity":"HIGH","note":"沒跑完"}]},
 {"repo":"acme/rails-app-1","pr":9903,"merged_at":"2026-08-03T00:00:00Z","fix_commits":[],
  "confirmed":true,
  "expected_findings":[{"path":"app/c.rb","line":30,"severity":"HIGH","note":"形狀不合法"}]}
]
J
cat > "$TMP/bin-idem/mra" <<'SHIM'
#!/usr/bin/env bash
case "$*" in
  *"--pr 9901"*) printf '%s' '{"status":"CHANGES_REQUESTED","summary":"x","comments":[
     {"path":"app/a.rb","line":11,"body":"x","severity":"HIGH"}]}' ;;
  *"--pr 9902"*) printf '%s' '{"status":"COMMENT","comments":[]}' ;;
  *"--pr 9903"*) printf '%s' '{"status":"CHANGES_REQUESTED","summary":"缺 comments"}' ;;
esac
SHIM
chmod +x "$TMP/bin-idem/mra"

# 第一輪：正常模式，9902 記成 incomplete、9903 記成 failed，兩者的輸出檔被刪
PATH="$TMP/bin-idem:$PATH" MRA_BENCHMARK_DIR="$ID_DIR" MRA_BACKTEST_MIN_COVERAGE=0 \
  bash "$S" --label idem >/dev/null 2>&1

# 第二輪與第三輪都用 --recompute。9902/9903 沒有現成輸出（第一輪刪了），所以
# 兩輪都是 RECOMPUTE_SKIP，結果必須一致。
PATH="$TMP/bin-idem:$PATH" MRA_BENCHMARK_DIR="$ID_DIR" MRA_BACKTEST_MIN_COVERAGE=0 \
  bash "$S" --label idem --tolerance 15 --recompute >/dev/null 2>&1
cp "$ID_DIR/runs/idem/summary.json" "$TMP/idem-run2.json"
PATH="$TMP/bin-idem:$PATH" MRA_BENCHMARK_DIR="$ID_DIR" MRA_BACKTEST_MIN_COVERAGE=0 \
  bash "$S" --label idem --tolerance 15 --recompute >/dev/null 2>&1
cp "$ID_DIR/runs/idem/summary.json" "$TMP/idem-run3.json"
if diff -q "$TMP/idem-run2.json" "$TMP/idem-run3.json" >/dev/null; then
  ok "--recompute 連跑兩次的 summary 完全相同"
else
  fail "--recompute 連跑兩次得到不同的 summary：$(diff "$TMP/idem-run2.json" "$TMP/idem-run3.json" | head -5)"
fi

# 直接驗刪檔這件事：在 --recompute 下放一個形狀不合法的檔案，跑完它要還在
printf '%s' '{"status":"CHANGES_REQUESTED","summary":"沒有 comments 欄位"}' \
  > "$ID_DIR/runs/idem/acme__rails-app-1__9903.json"
PATH="$TMP/bin-idem:$PATH" MRA_BENCHMARK_DIR="$ID_DIR" MRA_BACKTEST_MIN_COVERAGE=0 \
  bash "$S" --label idem --recompute >/dev/null 2>&1
if [ -f "$ID_DIR/runs/idem/acme__rails-app-1__9903.json" ]; then
  ok "--recompute 不刪形狀不合法的輸出檔（那是判斷原因的證據）"
else
  fail "--recompute 刪掉了輸出檔，違反它自己宣告的無副作用"
fi
# 對照：正常模式下同一個檔案要被刪掉
PATH="$TMP/bin-idem:$PATH" MRA_BENCHMARK_DIR="$ID_DIR" MRA_BACKTEST_MIN_COVERAGE=0 \
  bash "$S" --label idem >/dev/null 2>&1
if [ -f "$ID_DIR/runs/idem/acme__rails-app-1__9903.json" ]; then
  fail "正常模式下形狀不合法的輸出檔應該被刪（不然續跑會跳過它）"
else
  ok "正常模式下仍然刪除，--recompute 的例外沒有波及正常路徑"
fi

# --- confirmed 有值但一條 expected finding 都沒有 -------------------------
# `--set true` 做了、`--add` 還沒做的話，n_conf 是正的但每一筆的
# expected_findings 都是空陣列。跑出來的 summary 是 expected_total=0、三個率
# 全部 0、退出碼 0 —— 一份看起來完美的成績單，實際上什麼都沒量到。這跟
# NO_CONFIRMED 是同一種假象，只是少了一層。
NEF_DIR="$TMP/bench-nofindings"
mkdir -p "$NEF_DIR" "$TMP/bin-nef"
cat > "$NEF_DIR/candidates.json" <<'J'
[
 {"repo":"acme/rails-app-1","pr":8901,"merged_at":"2026-08-01T00:00:00Z","fix_commits":[],
  "confirmed":true,"expected_findings":[]},
 {"repo":"acme/rails-app-1","pr":8902,"merged_at":"2026-08-02T00:00:00Z","fix_commits":[],
  "confirmed":true,"expected_findings":[]}
]
J
cat > "$TMP/bin-nef/mra" <<'SHIM'
#!/usr/bin/env bash
echo "CALLED" >> "$MRA_TEST_CANARY"
printf '%s' '{"status":"APPROVED","summary":"x","comments":[]}'
SHIM
chmod +x "$TMP/bin-nef/mra"
NEF_CANARY="$TMP/nef-canary"; : > "$NEF_CANARY"
out_nef="$(PATH="$TMP/bin-nef:$PATH" MRA_BENCHMARK_DIR="$NEF_DIR" \
  MRA_TEST_CANARY="$NEF_CANARY" bash "$S" --label nef 2>&1)"
rc_nef=$?
[ "$rc_nef" -ne 0 ] && ok "全部 confirmed 但零 finding 時退出非 0" || fail "應該退出非 0"
has "用 NO_EXPECTED_FINDINGS 這個 token" "$out_nef" "NO_EXPECTED_FINDINGS"
has "訊息說明會看起來像滿分" "$out_nef" "看起來像滿分"
eq "擋下來時一次 review 都沒跑" "0" "$(wc -l < "$NEF_CANARY" | tr -d ' ')"
if [ -e "$NEF_DIR/runs/nef/summary.json" ]; then
  fail "不該輸出 summary.json（那份會是三個率全 0 的假滿分）"
else
  ok "沒有輸出假滿分的 summary.json"
fi

# 對照：只要有一條 finding 就放行
jq '.[0].expected_findings = [{"path":"app/a.rb","line":1,"severity":"HIGH","note":"x"}]' \
  "$NEF_DIR/candidates.json" > "$NEF_DIR/c.json"
mv "$NEF_DIR/c.json" "$NEF_DIR/candidates.json"
out_nef2="$(PATH="$TMP/bin-nef:$PATH" MRA_BENCHMARK_DIR="$NEF_DIR" \
  MRA_TEST_CANARY="$NEF_CANARY" MRA_BACKTEST_MIN_COVERAGE=0 bash "$S" --label nef2 2>&1)"
lacks "有 finding 時不再被擋" "$out_nef2" "NO_EXPECTED_FINDINGS"

# --- candidates_effective_sha 只對真正影響比較的部分敏感 ------------------
# candidates_sha 算整份檔案，加一筆 confirmed=false 的候選或重跑
# build-benchmark.sh 讓 fix_commits 換了，它就變 —— 兩輪看起來像換了基準集，
# 實際上分母一模一樣。
ESHA_DIR="$TMP/bench-esha"
mkdir -p "$ESHA_DIR" "$TMP/bin-esha"
cat > "$ESHA_DIR/candidates.json" <<'J'
[
 {"repo":"acme/rails-app-1","pr":9001,"merged_at":"2026-08-01T00:00:00Z",
  "fix_commits":[{"sha":"aaa","message":"fix: x"}],
  "confirmed":true,
  "expected_findings":[{"path":"app/a.rb","line":10,"severity":"HIGH","note":"x"}]}
]
J
cat > "$TMP/bin-esha/mra" <<'SHIM'
#!/usr/bin/env bash
printf '%s' '{"status":"APPROVED","summary":"x","comments":[]}'
SHIM
chmod +x "$TMP/bin-esha/mra"
run_esha() {
  PATH="$TMP/bin-esha:$PATH" MRA_BENCHMARK_DIR="$ESHA_DIR" MRA_BACKTEST_MIN_COVERAGE=0 \
    bash "$S" --label "$1" >/dev/null 2>&1
  jq -r '"\(.candidates_sha) \(.candidates_effective_sha)"' "$ESHA_DIR/runs/$1/summary.json"
}
base_shas="$(run_esha esha1)"

# 加一筆 confirmed=false 的候選：兩個 sha 應該一個變、一個不變
jq '. + [{"repo":"acme/rails-app-1","pr":9002,"merged_at":"2026-08-02T00:00:00Z",
          "fix_commits":[],"confirmed":false,"expected_findings":[]}]' \
  "$ESHA_DIR/candidates.json" > "$ESHA_DIR/c.json"
mv "$ESHA_DIR/c.json" "$ESHA_DIR/candidates.json"
after_unconfirmed="$(run_esha esha2)"
if [ "$(cut -d' ' -f1 <<<"$base_shas")" != "$(cut -d' ' -f1 <<<"$after_unconfirmed")" ]; then
  ok "加一筆未確認的候選：candidates_sha 變了（它算整份檔案）"
else
  fail "candidates_sha 應該變（整份檔案的內容確實改了）"
fi
eq "加一筆未確認的候選：candidates_effective_sha 不變" \
  "$(cut -d' ' -f2 <<<"$base_shas")" "$(cut -d' ' -f2 <<<"$after_unconfirmed")"

# 換掉 fix_commits：同樣一個變、一個不變
jq '.[0].fix_commits = [{"sha":"bbb","message":"fix: 重跑 build-benchmark 抓到不同的 commit"}]' \
  "$ESHA_DIR/candidates.json" > "$ESHA_DIR/c.json"
mv "$ESHA_DIR/c.json" "$ESHA_DIR/candidates.json"
after_fixcommits="$(run_esha esha3)"
eq "換掉 fix_commits：candidates_effective_sha 仍然不變" \
  "$(cut -d' ' -f2 <<<"$base_shas")" "$(cut -d' ' -f2 <<<"$after_fixcommits")"

# 真正改到 expected_findings：effective sha 一定要變
jq '.[0].expected_findings[0].line = 999' "$ESHA_DIR/candidates.json" > "$ESHA_DIR/c.json"
mv "$ESHA_DIR/c.json" "$ESHA_DIR/candidates.json"
after_findings="$(run_esha esha4)"
if [ "$(cut -d' ' -f2 <<<"$base_shas")" != "$(cut -d' ' -f2 <<<"$after_findings")" ]; then
  ok "改到 expected_findings：candidates_effective_sha 變了"
else
  fail "改到 expected_findings 時 effective sha 必須變，不然它偵測不到基準集換了"
fi

# expected_findings 的順序不該影響 effective sha（--add 的先後是任意的）
jq '.[0].expected_findings = [{"path":"app/b.rb","line":20,"severity":"LOW","note":"y"},
                              {"path":"app/a.rb","line":10,"severity":"HIGH","note":"x"}]' \
  "$ESHA_DIR/candidates.json" > "$ESHA_DIR/c.json"
mv "$ESHA_DIR/c.json" "$ESHA_DIR/candidates.json"
order1="$(run_esha esha5)"
jq '.[0].expected_findings = [{"path":"app/a.rb","line":10,"severity":"HIGH","note":"x"},
                              {"path":"app/b.rb","line":20,"severity":"LOW","note":"y"}]' \
  "$ESHA_DIR/candidates.json" > "$ESHA_DIR/c.json"
mv "$ESHA_DIR/c.json" "$ESHA_DIR/candidates.json"
order2="$(run_esha esha6)"
eq "expected_findings 的順序不影響 effective sha" \
  "$(cut -d' ' -f2 <<<"$order1")" "$(cut -d' ' -f2 <<<"$order2")"


# --- 分層 persona：逐 PR 依 repo 所屬層切換 MRA_PERSONAS_DIR -----------------
# 這是分層注入在 review 端的另一半。注入產出的是「每層一份 persona 目錄」
# （lib/rule-inject.sh 的 rule_inject_layers），要有人在跑的時候依 repo 把
# MRA_PERSONAS_DIR 指到對的那一份，rails 層的規則才會真的進到 Rails PR 的
# prompt。
#
# 兩個 repo 刻意分屬不同層（acme/rails-app-1 是 rails、acme/react-app-1 是
# react，見 lib/corpus-internal.sh 的對應表）：只用一個 repo 的話，一個把
# 每個 PR 都指到同一個固定目錄的退化實作也會通過，而那等於沒有分層。
LAYER_DIR="$TMP/layer-bench"
mkdir -p "$LAYER_DIR"
cat > "$LAYER_DIR/candidates.json" <<'J'
[
 {"repo":"acme/rails-app-1","pr":9001,"merged_at":"2026-08-01T00:00:00Z","fix_commits":[],
  "confirmed":true,
  "expected_findings":[{"path":"app/a.rb","line":10,"severity":"HIGH","note":"a"}]},
 {"repo":"acme/react-app-1","pr":9002,"merged_at":"2026-08-02T00:00:00Z","fix_commits":[],
  "confirmed":true,
  "expected_findings":[{"path":"src/a.tsx","line":10,"severity":"HIGH","note":"b"}]}
]
J

PERSONAS_ROOT_DIR="$TMP/layer-personas"
mkdir -p "$PERSONAS_ROOT_DIR/common" "$PERSONAS_ROOT_DIR/rails" \
         "$PERSONAS_ROOT_DIR/react" "$PERSONAS_ROOT_DIR/vue" "$PERSONAS_ROOT_DIR/nestjs"

# 這個 shim 把每次 review 收到的 MRA_PERSONAS_DIR 連同 argv 一起記下來，
# 才斷言得出「哪個 PR 用了哪一層」，不是只看「有沒有設過這個變數」。
cat > "$TMP/bin/mra-layer" <<SHIM
#!/usr/bin/env bash
printf '%s\t%s\n' "\$*" "\${MRA_PERSONAS_DIR:-<unset>}" >> "$TMP/persona-usage.log"
printf '%s' '{"status":"APPROVED","summary":"x","comments":[]}'
SHIM
chmod +x "$TMP/bin/mra-layer"

: > "$TMP/persona-usage.log"
layer_out="$(MRA_BENCHMARK_DIR="$LAYER_DIR" MRA_BACKTEST_CMD="mra-layer" \
  MRA_PERSONAS_ROOT="$PERSONAS_ROOT_DIR" bash "$S" --label layered 2>&1)"
layer_rc=$?
eq "分層回測退出碼 0" "0" "$layer_rc"
eq "Rails repo 的 PR 讀 rails 層的 persona" "$PERSONAS_ROOT_DIR/rails" \
  "$(grep -- '--pr 9001' "$TMP/persona-usage.log" | cut -f2)"
eq "React repo 的 PR 讀 react 層的 persona" "$PERSONAS_ROOT_DIR/react" \
  "$(grep -- '--pr 9002' "$TMP/persona-usage.log" | cut -f2)"
has "開跑前印出 repo 與層的對應" "$layer_out" "acme/rails-app-1 → rails 層"

# 沒設 MRA_PERSONAS_ROOT 時完全不碰 MRA_PERSONAS_DIR：分層是可選的，既有的
# 呼叫方式（整輪共用一個 MRA_PERSONAS_DIR，或用內建 agents/personas）必須
# 一個字元都不變，否則階段二的基準線就不能拿來比了。
: > "$TMP/persona-usage.log"
MRA_BENCHMARK_DIR="$LAYER_DIR" MRA_BACKTEST_CMD="mra-layer" \
  bash "$S" --label unlayered >/dev/null 2>&1
eq "沒開分層時 MRA_PERSONAS_DIR 維持未設定" "<unset>" \
  "$(grep -- '--pr 9001' "$TMP/persona-usage.log" | cut -f2)"

# 查不到所屬層的 repo 要在開跑之前擋下來，不是退回 common 跑完：退回去的話
# 那個 repo 的 PR 會用一份不含自己這層規則的 prompt 跑完，而 summary 看起來
# 完全正常——事後查不出來那一層到底有沒有被測到。
UNKNOWN_DIR="$TMP/layer-unknown"
mkdir -p "$UNKNOWN_DIR"
jq '[.[0] | .repo = "someorg/not-registered"]' "$LAYER_DIR/candidates.json" \
  > "$UNKNOWN_DIR/candidates.json"
: > "$TMP/persona-usage.log"
unknown_out="$(MRA_BENCHMARK_DIR="$UNKNOWN_DIR" MRA_BACKTEST_CMD="mra-layer" \
  MRA_PERSONAS_ROOT="$PERSONAS_ROOT_DIR" bash "$S" --label unknown-layer 2>&1)"
unknown_rc=$?
if [[ "$unknown_rc" -ne 0 ]]; then
  ok "查不到層的 repo 讓回測退出碼非 0"
else
  fail "查不到層的 repo 必須擋下來，不能照跑：rc=$unknown_rc"
fi
has "印出 REPO_LAYER_UNKNOWN" "$unknown_out" "REPO_LAYER_UNKNOWN"
eq "擋下來時一次 review 都沒跑" "" "$(cat "$TMP/persona-usage.log")"

# 某一層的目錄不存在同樣要在開跑之前擋下來。一輪回測要幾小時，跑到第 20 個
# PR 才發現 react 層的目錄不存在，前面的時間就白燒了。
MISSING_ROOT="$TMP/layer-personas-missing"
mkdir -p "$MISSING_ROOT/rails"
: > "$TMP/persona-usage.log"
missing_out="$(MRA_BENCHMARK_DIR="$LAYER_DIR" MRA_BACKTEST_CMD="mra-layer" \
  MRA_PERSONAS_ROOT="$MISSING_ROOT" bash "$S" --label missing-layer 2>&1)"
missing_rc=$?
if [[ "$missing_rc" -ne 0 ]]; then
  ok "缺一層的 persona 目錄讓回測退出碼非 0"
else
  fail "缺一層的 persona 目錄必須擋下來：rc=$missing_rc"
fi
has "印出 PERSONAS_LAYER_MISSING" "$missing_out" "PERSONAS_LAYER_MISSING"
eq "缺目錄時一次 review 都沒跑" "" "$(cat "$TMP/persona-usage.log")"

# MRA_PERSONAS_ROOT 指到一個根本不存在的路徑：同樣是硬失敗，不是退回內建
# persona 靜默跑完。
nonroot_out="$(MRA_BENCHMARK_DIR="$LAYER_DIR" MRA_BACKTEST_CMD="mra-layer" \
  MRA_PERSONAS_ROOT="$TMP/does-not-exist-root" bash "$S" --label no-root 2>&1)"
nonroot_rc=$?
if [[ "$nonroot_rc" -ne 0 ]]; then
  ok "MRA_PERSONAS_ROOT 不是目錄時退出碼非 0"
else
  fail "MRA_PERSONAS_ROOT 不是目錄必須擋下來：rc=$nonroot_rc"
fi
has "印出 PERSONAS_ROOT_MISSING" "$nonroot_out" "PERSONAS_ROOT_MISSING"

# --recompute 一次 review 都不跑，載入哪一份 persona 完全不影響結果。注入後的
# persona 放在 TMPDIR 底下，換容差重算時它可能早就被系統清掉了——為一個根本
# 不會被讀到的目錄擋下重算是誤擋。label layered 上面已經跑完，這裡直接重算。
recompute_out="$(MRA_BENCHMARK_DIR="$LAYER_DIR" MRA_BACKTEST_CMD="mra-layer" \
  MRA_PERSONAS_ROOT="$TMP/does-not-exist-root" bash "$S" --label layered --recompute 2>&1)"
recompute_rc=$?
eq "--recompute 不因為 persona 目錄不見而被擋下" "0" "$recompute_rc"
lacks "--recompute 不做分層預檢" "$recompute_out" "PERSONAS_ROOT_MISSING"

# --- 算不出指標的 PR 不能污染彙總 ------------------------------------------
#
# expected_findings 裡混進一個字串（不是 {path,line,severity,note} 物件）時，
# backtest_match 的 `.value.path` 會對字串報錯。這種畸形資料真的寫得出來：
# candidates.json 沒有 schema，review-benchmark.sh --add 以外的手動編輯就會。
#
# 舊版兩件事都沒做對：backtest_match 的退出碼完全沒接（$m 變成空字串，之後
# 每一個 --argjson 連鎖失敗，整輪回測報廢），backtest_file_missed 又放在
# all_matches／all_comments 攤平之後（那個 PR 的 match 與 comment 已經進了
# 彙總，continue 只跳過 prs 計數，於是 expected_total 含它、覆蓋率的分子不含
# 它，anchor_drift 也跟著多算）。修好之後那一筆只記成 failed，其餘照常。
BAD_DIR="$TMP/bad-expected"
mkdir -p "$BAD_DIR"
cat > "$BAD_DIR/candidates.json" <<'J'
[
 {"repo":"acme/rails-app-1","pr":9201,"merged_at":"2026-08-01T00:00:00Z","fix_commits":[],
  "confirmed":true,
  "expected_findings":[{"path":"app/a.rb","line":10,"severity":"HIGH","note":"a"}]},
 {"repo":"acme/rails-app-1","pr":9202,"merged_at":"2026-08-02T00:00:00Z","fix_commits":[],
  "confirmed":true,
  "expected_findings":["這一筆是字串，不是物件"]}
]
J

cat > "$TMP/bin/mra-bad" <<'SHIM'
#!/usr/bin/env bash
case "$*" in
  *"--pr 9201"*)
    printf '%s' '{"status":"CHANGES_REQUESTED","summary":"x","comments":[
     {"path":"app/a.rb","line":11,"body":"x","severity":"HIGH"}]}' ;;
  *"--pr 9202"*)
    printf '%s' '{"status":"CHANGES_REQUESTED","summary":"x","comments":[
     {"path":"app/z.rb","line":1,"body":"x","severity":"LOW"},
     {"path":"app/z2.rb","line":2,"body":"x","severity":"LOW"}]}' ;;
esac
SHIM
chmod +x "$TMP/bin/mra-bad"

bad_out="$(MRA_BENCHMARK_DIR="$BAD_DIR" MRA_BACKTEST_CMD="mra-bad" \
  MRA_BACKTEST_MIN_COVERAGE=0.5 bash "$S" --label bad-expected 2>&1)"
bad_rc=$?
eq "一筆畸形 expected 不會讓整輪回測報廢" "0" "$bad_rc"
BAD_SUM="$BAD_DIR/runs/bad-expected/summary.json"
if [[ -s "$BAD_SUM" ]]; then ok "仍然產出 summary.json"; else fail "沒有 summary.json：$bad_out"; fi
eq "只有好的那筆計入 prs" "1" "$(jq -r '.prs' "$BAD_SUM")"
eq "畸形的那筆記成 failed" "1" "$(jq -r '.failed_count' "$BAD_SUM")"
eq "failed 清單點名 9202" "acme/rails-app-1#9202" "$(jq -r '.failed_prs[0]' "$BAD_SUM")"
# 這兩條是關鍵：畸形的那筆有 2 則 comment，它們絕對不能出現在彙總裡。
eq "expected_total 只含好的那筆" "1" "$(jq -r '.expected_total' "$BAD_SUM")"
eq "comments_total 只含好的那筆" "1" "$(jq -r '.comments_total' "$BAD_SUM")"

echo "---"; echo "Passed: $pass"; echo "Failed: $errors"
exit $((errors > 0 ? 1 : 0))
