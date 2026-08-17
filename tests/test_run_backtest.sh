#!/usr/bin/env bash
# 回測執行 (scripts/run-backtest.sh)。用 PATH shim 假造 mra，不呼叫 LLM、不連網路。
#
# 基準集刻意用三筆 confirmed=true、期望數不均(1、3、7 筆)，讓「攤平計數後
# 算一次」跟「每個 PR 各自算一次再平均」在 miss_rate／unmatched_rate／
# severity_rate 上都會算出不同數字——本檔的斷言只認前者，逐項用手算的加總
# 值釘住。confirmed=false 與 confirmed=null 的列各留一筆，讓跳過與否可觀察。
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

# --- 基準集：三筆 confirmed=true(期望數 1、3、7，刻意不均)、一筆 review 會
# 失敗的 confirmed=true(7004)、一筆 confirmed=false(7005)、一筆
# confirmed=null(7006) --------------------------------------------------
cat > "$C" <<'J'
[
 {"repo":"acme/rails-app-1","pr":7001,"merged_at":"2026-08-01T00:00:00Z","fix_commits":[],
  "confirmed":true,
  "expected_findings":[{"path":"app/a.rb","line":10,"severity":"HIGH","note":"nil 未處理"}]},
 {"repo":"acme/rails-app-1","pr":7002,"merged_at":"2026-08-02T00:00:00Z","fix_commits":[],
  "confirmed":true,
  "expected_findings":[
   {"path":"app/b1.rb","line":20,"severity":"HIGH","note":"b1"},
   {"path":"app/b2.rb","line":40,"severity":"MEDIUM","note":"b2"},
   {"path":"app/b3.rb","line":60,"severity":"LOW","note":"b3"}]},
 {"repo":"acme/rails-app-1","pr":7003,"merged_at":"2026-08-03T00:00:00Z","fix_commits":[],
  "confirmed":true,
  "expected_findings":[
   {"path":"app/c1.rb","line":1,"severity":"HIGH","note":"c1"},
   {"path":"app/c2.rb","line":2,"severity":"HIGH","note":"c2"},
   {"path":"app/c3.rb","line":3,"severity":"HIGH","note":"c3"},
   {"path":"app/c4.rb","line":4,"severity":"HIGH","note":"c4"},
   {"path":"app/c5.rb","line":5,"severity":"HIGH","note":"c5"},
   {"path":"app/c6.rb","line":6,"severity":"HIGH","note":"c6"},
   {"path":"app/c7.rb","line":7,"severity":"HIGH","note":"c7"}]},
 {"repo":"acme/rails-app-1","pr":7004,"merged_at":"2026-08-04T00:00:00Z","fix_commits":[],
  "confirmed":true,
  "expected_findings":[{"path":"app/x.rb","line":1,"severity":"HIGH","note":"x"}]},
 {"repo":"acme/rails-app-1","pr":7005,"merged_at":"2026-08-05T00:00:00Z","fix_commits":[],
  "confirmed":false,"expected_findings":[]},
 {"repo":"acme/rails-app-1","pr":7006,"merged_at":"2026-08-06T00:00:00Z","fix_commits":[],
  "confirmed":null,"expected_findings":[]}
]
J

# 手算(加總後才算一次率，不是逐 PR 算率再平均)：
#   expected_total = 1+3+7 = 11
#   missed         = 1+0+6 = 7   → miss_rate       = 7/11  = 0.6364 → 0.64
#   comments_total = 0+4+3 = 7
#   unmatched      = 0+1+2 = 3   → unmatched_rate  = 3/7   = 0.4286 → 0.43
#   severity_agree = 0+2+1 = 3   (命中數 4 筆)     severity_rate   = 3/4   = 0.75
# 若改成逐 PR 算率再平均：miss_rate 三筆各是 1.0、0.0、6/7，平均約 0.62，
# 跟加總後的 0.64 不同——這就是本檔要釘住加總值、不是平均值的原因。

# --- mra shim：baseline label ------------------------------------------
cat > "$TMP/bin/mra" <<'SHIM'
#!/usr/bin/env bash
case "$*" in
  *"--pr 7001"*)
    printf '%s' '{"status":"COMMENT","summary":"x","comments":[]}' ;;
  *"--pr 7002"*)
    printf '%s' '{"status":"CHANGES_REQUESTED","summary":"x","comments":[
     {"path":"app/b1.rb","line":21,"body":"x","severity":"HIGH"},
     {"path":"app/b2.rb","line":41,"body":"x","severity":"HIGH"},
     {"path":"app/b3.rb","line":60,"body":"x","severity":"LOW"},
     {"path":"app/extra1.rb","line":5,"body":"x","severity":"LOW"}]}' ;;
  *"--pr 7003"*)
    printf '%s' '{"status":"CHANGES_REQUESTED","summary":"x","comments":[
     {"path":"app/c1.rb","line":1,"body":"x","severity":"HIGH"},
     {"path":"app/extra2.rb","line":50,"body":"x","severity":"LOW"},
     {"path":"app/extra3.rb","line":60,"body":"x","severity":"LOW"}]}' ;;
  *"--pr 7004"*)
    exit 1 ;;
  *"--pr 7005"*|*"--pr 7006"*)
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
if [[ -s "$R/acme__rails-app-1__7001.json" ]]; then ok "7001 有輸出檔"; else fail "沒跑 7001"; fi
if [[ -s "$R/acme__rails-app-1__7002.json" ]]; then ok "7002 有輸出檔"; else fail "沒跑 7002"; fi
if [[ -s "$R/acme__rails-app-1__7003.json" ]]; then ok "7003 有輸出檔"; else fail "沒跑 7003"; fi
if [[ -e "$R/acme__rails-app-1__7004.json" ]]; then fail "7004 review 失敗不該留檔"; else ok "7004 review 失敗沒有殘留輸出檔"; fi
if [[ -e "$R/acme__rails-app-1__7005.json" ]]; then fail "不該跑 confirmed=false 的 7005"; else ok "跳過 confirmed=false(7005)"; fi
if [[ -e "$R/acme__rails-app-1__7006.json" ]]; then fail "不該跑 confirmed=null 的 7006"; else ok "跳過 confirmed=null(7006)"; fi

err_baseline_text="$(cat "$err_baseline")"
has  "7004 review 失敗有印出 REVIEW_FAILED" "$err_baseline_text" "REVIEW_FAILED"
has  "REVIEW_FAILED 訊息指名 7004" "$err_baseline_text" "acme/rails-app-1#7004"

S1="$R/summary.json"
eq "prs 數為 3(7004/7005/7006 都不計入)" "3"    "$(jq -r '.prs' "$S1")"
eq "期望總數 11(1+3+7 加總)"            "11"   "$(jq -r '.expected_total' "$S1")"
eq "漏抓數 7(加總，非逐 PR 平均)"        "7"    "$(jq -r '.missed' "$S1")"
eq "漏抓率 0.64(加總後算一次)"           "0.64" "$(jq -r '.miss_rate' "$S1")"
eq "comment 總數 7(加總)"               "7"    "$(jq -r '.comments_total' "$S1")"
eq "未對應數 3(跨 PR 攤平後仍要對準各自的 comment，不是位置互相污染)" "3" \
  "$(jq -r '.unmatched' "$S1")"
eq "未對應率 0.43"                      "0.43" "$(jq -r '.unmatched_rate' "$S1")"
eq "嚴重度吻合數 3"                     "3"    "$(jq -r '.severity_agree' "$S1")"
eq "嚴重度吻合率 0.75"                   "0.75" "$(jq -r '.severity_rate' "$S1")"

# --- mra shim：after label(輸出跟 baseline 完全不同，--compare 才有東西可比)
cat > "$TMP/bin/mra" <<'SHIM'
#!/usr/bin/env bash
case "$*" in
  *"--pr 7001"*)
    printf '%s' '{"status":"CHANGES_REQUESTED","summary":"x","comments":[
     {"path":"app/a.rb","line":12,"body":"x","severity":"HIGH"}]}' ;;
  *"--pr 7002"*)
    printf '%s' '{"status":"CHANGES_REQUESTED","summary":"x","comments":[
     {"path":"app/b1.rb","line":20,"body":"x","severity":"HIGH"},
     {"path":"app/b2.rb","line":40,"body":"x","severity":"MEDIUM"},
     {"path":"app/b3.rb","line":60,"body":"x","severity":"LOW"}]}' ;;
  *"--pr 7003"*)
    printf '%s' '{"status":"CHANGES_REQUESTED","summary":"x","comments":[
     {"path":"app/c1.rb","line":1,"body":"x","severity":"HIGH"},
     {"path":"app/c2.rb","line":2,"body":"x","severity":"HIGH"},
     {"path":"app/c3.rb","line":3,"body":"x","severity":"MEDIUM"}]}' ;;
  *"--pr 7004"*)
    exit 1 ;;
  *"--pr 7005"*|*"--pr 7006"*)
    printf '%s' '{"status":"APPROVED","summary":"x","comments":[]}' ;;
  *)
    echo "unexpected mra invocation: $*" >&2; exit 1 ;;
esac
SHIM
chmod +x "$TMP/bin/mra"

# 手算(after)：expected_total=11、missed=0+0+4=4→miss_rate=4/11=0.36、
# comments_total=1+3+3=7、unmatched=0→unmatched_rate=0、
# severity_agree=1+3+2=6(命中 7 筆，c3 嚴重度錯)→severity_rate=6/7=0.86。
bash "$S" --label after >"$TMP/after.out" 2>"$TMP/after.err"
eq "after 退出碼 0" "0" "$?"

S2="$MRA_BENCHMARK_DIR/runs/after/summary.json"
eq "after prs 數為 3"        "3"    "$(jq -r '.prs' "$S2")"
eq "after 期望總數 11"       "11"   "$(jq -r '.expected_total' "$S2")"
eq "after 漏抓數 4"          "4"    "$(jq -r '.missed' "$S2")"
eq "after 漏抓率 0.36"       "0.36" "$(jq -r '.miss_rate' "$S2")"
eq "after 未對應數 0"        "0"    "$(jq -r '.unmatched' "$S2")"
eq "after 未對應率 0"        "0"    "$(jq -r '.unmatched_rate' "$S2")"
eq "after 嚴重度吻合數 6"    "6"    "$(jq -r '.severity_agree' "$S2")"
eq "after 嚴重度吻合率 0.86" "0.86" "$(jq -r '.severity_rate' "$S2")"

# --- --compare：baseline 跟 after 的數字明顯不同，兩欄不能互相污染 -------
cmp_out="$(bash "$S" --compare baseline after)"
eq "compare 結束碼 0" "0" "$?"

header_line="$(printf '%-18s %10s %10s' "指標" "baseline" "after")"
has "compare 表頭含兩個 label" "$cmp_out" "$header_line"

miss_line="$(printf '%-18s %10s %10s' "miss_rate" "0.64" "0.36")"
has "compare miss_rate 列 A/B 欄不同(baseline 0.64、after 0.36 沒被弄混)" \
  "$cmp_out" "$miss_line"

sev_line="$(printf '%-18s %10s %10s' "severity_agree" "3" "6")"
has "compare severity_agree 列 A/B 欄不同(baseline 3、after 6 沒被弄混)" \
  "$cmp_out" "$sev_line"

unmatched_line="$(printf '%-18s %10s %10s' "unmatched_rate" "0.43" "0")"
has "compare unmatched_rate 列 A/B 欄不同(baseline 0.43、after 0 沒被弄混)" \
  "$cmp_out" "$unmatched_line"

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
