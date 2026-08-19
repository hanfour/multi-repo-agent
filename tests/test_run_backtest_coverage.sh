#!/usr/bin/env bash
# scripts/run-backtest.sh：覆蓋率下限（成功納入彙總的 PR 數／confirmed 總數）。
#
# 背景：基準線 C 跑到一半 claude 的 OAuth session 過期，38 筆裡 34 筆失敗，
# 只剩不具代表性的前 4 筆算出指標，其中一個(severity_rate)剛好是完美的
# 1.0，單看這幾個數字會誤判成「這個模式大幅優於現況」。既有的
# ALL_REVIEWS_FAILED 只防「完全沒跑成」($prs == 0)，沒防「跑成的太少」，
# 這支測試釘住的是新增的那道防線：成功比例低於門檻時，退出非 0、印
# COVERAGE_TOO_LOW，而且絕對不能寫出（或覆寫掉）summary.json：半調子的
# summary 比完全沒有 summary 更危險，因為它看起來正常。
#
# 沿用 tests/test_run_backtest.sh 的作法：PATH shim 假造 mra，不呼叫
# LLM、不連網路。用 10 筆 confirmed=true 的 PR，其中 7 筆成功、3 筆失敗，
# 湊出 7/10 = 0.7 這個乾淨的比例，方便跟預設門檻 0.8、以及自訂門檻互相
# 比對，不用為每個門檻案例各自準備一組新 fixture。
set -uo pipefail
MRA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
S="$MRA_DIR/scripts/run-backtest.sh"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/run-backtest-coverage-test.XXXXXX")"
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

C="$MRA_BENCHMARK_DIR/candidates.json"

# --- 7/10 成功的基準集：9201~9207 成功、9208~9210 失敗 --------------------
jq -n '[range(9201;9211) | {repo:"acme/rails-app-1", pr:., merged_at:"2026-08-10T00:00:00Z",
        fix_commits:[], confirmed:true, expected_findings:[]}]' > "$C"

cat > "$TMP/bin/mra" <<'SHIM'
#!/usr/bin/env bash
case "$*" in
  *"--pr 9201"*|*"--pr 9202"*|*"--pr 9203"*|*"--pr 9204"*|*"--pr 9205"*|*"--pr 9206"*|*"--pr 9207"*)
    printf '%s' '{"status":"APPROVED","summary":"x","comments":[]}' ;;
  *"--pr 9208"*|*"--pr 9209"*|*"--pr 9210"*)
    echo "stub failure" >&2
    exit 1 ;;
  *)
    echo "unexpected mra invocation: $*" >&2; exit 1 ;;
esac
SHIM
chmod +x "$TMP/bin/mra"

# --- 案例 1：覆蓋率低於預設門檻(0.7 < 0.8)：退出非 0、印 COVERAGE_TOO_LOW，
#     而且不能覆寫掉既有的 summary.json ----------------------------------
R_BELOW="$MRA_BENCHMARK_DIR/runs/below"
mkdir -p "$R_BELOW"
SENTINEL='{"sentinel":"pre-existing summary must survive a COVERAGE_TOO_LOW run untouched"}'
printf '%s' "$SENTINEL" > "$R_BELOW/summary.json"

err_below="$TMP/below.err"
bash "$S" --label below >"$TMP/below.out" 2>"$err_below"
rc_below=$?
if [[ "$rc_below" -ne 0 ]]; then
  ok "覆蓋率低於門檻：退出碼非 0"
else
  fail "覆蓋率低於門檻：應該退出非 0，實際是 0"
fi
err_below_text="$(cat "$err_below")"
has "覆蓋率低於門檻：stderr 有印出 COVERAGE_TOO_LOW" "$err_below_text" "COVERAGE_TOO_LOW"
has "覆蓋率低於門檻：訊息裡有實際比例 0.7" "$err_below_text" "0.7"
has "覆蓋率低於門檻：訊息裡有門檻值 0.8" "$err_below_text" "0.8"
has "覆蓋率低於門檻：訊息說明這一輪的數字不可用、不是 review 品質問題" \
  "$err_below_text" "不是 review 品質問題"

# 最重要的一條：已經存在的 summary.json 不能被這次失敗的跑動覆寫掉。
actual_after="$(cat "$R_BELOW/summary.json")"
eq "覆蓋率低於門檻：既有 summary.json 內容維持原樣，沒有被覆寫" "$SENTINEL" "$actual_after"

# --- 案例 1b：同樣的低覆蓋率，但這次事先沒有 summary.json，跑完也不該生出來
R_BELOW2="$MRA_BENCHMARK_DIR/runs/below2"
bash "$S" --label below2 >"$TMP/below2.out" 2>"$TMP/below2.err"
if [[ -e "$R_BELOW2/summary.json" ]]; then
  fail "覆蓋率低於門檻(事先沒有 summary.json)：不該生出 summary.json"
else
  ok "覆蓋率低於門檻(事先沒有 summary.json)：跑完仍然沒有 summary.json"
fi

# --- 案例 2：自訂門檻剛好等於實際比例(0.7)時通過(邊界，用 < 不用 <=) -----
err_boundary="$TMP/boundary.err"
MRA_BACKTEST_MIN_COVERAGE=0.7 bash "$S" --label boundary >"$TMP/boundary.out" 2>"$err_boundary"
rc_boundary=$?
eq "門檻剛好等於實際比例：退出碼 0(通過)" "0" "$rc_boundary"
R_BOUNDARY="$MRA_BENCHMARK_DIR/runs/boundary"
if [[ -s "$R_BOUNDARY/summary.json" ]]; then
  ok "門檻剛好等於實際比例：summary.json 正常寫出"
else
  fail "門檻剛好等於實際比例：summary.json 沒有寫出"
fi
eq "門檻剛好等於實際比例：prs 是 7" "7" "$(jq -r '.prs' "$R_BOUNDARY/summary.json")"

# --- 案例 3：MRA_BACKTEST_MIN_COVERAGE=0 等同停用這道檢查 ------------------
err_disabled="$TMP/disabled.err"
MRA_BACKTEST_MIN_COVERAGE=0 bash "$S" --label disabled >"$TMP/disabled.out" 2>"$err_disabled"
rc_disabled=$?
eq "門檻設 0：退出碼 0(等同停用)" "0" "$rc_disabled"
R_DISABLED="$MRA_BENCHMARK_DIR/runs/disabled"
if [[ -s "$R_DISABLED/summary.json" ]]; then
  ok "門檻設 0：summary.json 正常寫出"
else
  fail "門檻設 0：summary.json 沒有寫出"
fi
disabled_err_text="$(cat "$err_disabled")"
if [[ "$disabled_err_text" == *"COVERAGE_TOO_LOW"* ]]; then
  fail "門檻設 0：不該印出 COVERAGE_TOO_LOW"
else
  ok "門檻設 0：沒有印出 COVERAGE_TOO_LOW"
fi

# --- 案例 4：MRA_BACKTEST_MIN_COVERAGE 給非法數字時，用專屬 token 擋下來 --
err_invalid="$TMP/invalid.err"
MRA_BACKTEST_MIN_COVERAGE=not-a-number bash "$S" --label invalid >"$TMP/invalid.out" 2>"$err_invalid"
rc_invalid=$?
if [[ "$rc_invalid" -ne 0 ]]; then
  ok "門檻給非法數字：退出碼非 0"
else
  fail "門檻給非法數字：應該退出非 0"
fi
has "門檻給非法數字：印出 MIN_COVERAGE_INVALID" "$(cat "$err_invalid")" "MIN_COVERAGE_INVALID"

# --- 案例 5：全部成功時，行為完全不變(不受這道新檢查影響) ------------------
C2="$MRA_BENCHMARK_DIR/candidates-all-ok.json"
jq -n '[9301,9302,9303] | map({repo:"acme/rails-app-1", pr:., merged_at:"2026-08-11T00:00:00Z",
        fix_commits:[], confirmed:true, expected_findings:[]})' > "$C2"
cat > "$TMP/bin/mra" <<'SHIM2'
#!/usr/bin/env bash
case "$*" in
  *"--pr 9301"*|*"--pr 9302"*|*"--pr 9303"*)
    printf '%s' '{"status":"APPROVED","summary":"x","comments":[]}' ;;
  *)
    echo "unexpected mra invocation: $*" >&2; exit 1 ;;
esac
SHIM2
chmod +x "$TMP/bin/mra"
cp "$C2" "$C"

err_allok="$TMP/allok.err"
bash "$S" --label allok >"$TMP/allok.out" 2>"$err_allok"
rc_allok=$?
eq "全部成功：退出碼 0" "0" "$rc_allok"
R_ALLOK="$MRA_BENCHMARK_DIR/runs/allok"
eq "全部成功：prs 是 3" "3" "$(jq -r '.prs' "$R_ALLOK/summary.json")"
allok_err_text="$(cat "$err_allok")"
if [[ "$allok_err_text" == *"COVERAGE_TOO_LOW"* ]]; then
  fail "全部成功：不該印出 COVERAGE_TOO_LOW"
else
  ok "全部成功：沒有印出 COVERAGE_TOO_LOW"
fi

echo "---"; echo "Passed: $pass"; echo "Failed: $errors"
exit $((errors > 0 ? 1 : 0))
