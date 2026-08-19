#!/usr/bin/env bash
# scripts/backtest-review-adapter.sh：接住 run-backtest.sh 呼叫的假想 mra CLI
# 形狀(review <owner/repo> --pr <N> --strategy personas --json)，轉譯成真正
# mra review 吃得下的呼叫。用 stub 取代 gh 與 bin/mra.sh，不連網路、不呼叫
# 真正的模型。
#
# bin/mra.sh 的路徑不是可覆寫的 env(跟 run-backtest.sh 的 MRA_BACKTEST_CMD
# 不一樣)，是照 "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" 算出來的、
# 跟這支 adapter 腳本自己實際被呼叫的路徑綁在一起。要讓它指到 stub，這裡把
# adapter 腳本本尊「符號連結」進一個假的專案樹(fake/scripts/ 底下)。
# fake/bin/mra.sh 放 stub，腳本自己算出來的 MRA_DIR 會是 fake/，不是這個
# repo 的真正根目錄，`$MRA_DIR/bin/mra.sh` 自然就是 stub。
set -uo pipefail

MRA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REAL_ADAPTER="$MRA_DIR/scripts/backtest-review-adapter.sh"

errors=0; pass=0
ok()   { echo "PASS: $1"; pass=$((pass+1)); }
fail() { echo "FAIL: $1"; errors=$((errors+1)); }
eq()   { if [[ "$2" == "$3" ]]; then ok "$1"; else fail "$1 — expected [$2] got [$3]"; fi; }
has()  { case "$2" in *"$3"*) ok "$1" ;; *) fail "$1 — 沒看到「$3」：$2" ;; esac; }
lacks(){ case "$2" in *"$3"*) fail "$1 — 不該看到「$3」：$2" ;; *) ok "$1" ;; esac; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/backtest-adapter-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

FAKE="$TMP/fake"
mkdir -p "$FAKE/scripts" "$FAKE/bin"
ln -s "$REAL_ADAPTER" "$FAKE/scripts/backtest-review-adapter.sh"
ADAPTER="$FAKE/scripts/backtest-review-adapter.sh"

# gh 是裸命令查找，用 PATH 前置一個 stub 目錄就能接住。
STUBBIN="$TMP/stubbin"
mkdir -p "$STUBBIN"
export PATH="$STUBBIN:$PATH"

WS="$TMP/ws"
mkdir -p "$WS"
export MRA_BACKTEST_WORKSPACE="$WS"

R="$WS/erp"
git -C "$R" init -q -b main 2>/dev/null || { mkdir -p "$R"; git -C "$R" init -q -b main; }
git -C "$R" config user.email t@t.t; git -C "$R" config user.name t
printf 'one\n' > "$R/f.txt"; git -C "$R" add f.txt; git -C "$R" commit -q -m base
BASE_SHA="$(git -C "$R" rev-parse HEAD)"
printf 'two\n' >> "$R/f.txt"; git -C "$R" add f.txt; git -C "$R" commit -q -m head
HEAD_SHA="$(git -C "$R" rev-parse HEAD)"

STUB_REVIEW_JSON='{"status":"CHANGES_REQUESTED","summary":"stub","comments":[{"path":"app/a.rb","line":10,"severity":"HIGH","body":"x"}]}'

# 寫 gh stub。$1：base sha 要印的值(留空代表印 null)。$2：exit code。
write_gh_stub() {
  local base="$1" rc="${2:-0}"
  cat > "$STUBBIN/gh" <<EOF
#!/usr/bin/env bash
if [[ "\$*" == *"pulls/101"* ]]; then
  if [[ "$rc" != "0" ]]; then exit $rc; fi
  if [[ -z "$base" ]]; then
    printf '%s' '{"base":{"sha":null},"head":{"sha":"$HEAD_SHA"}}'
  else
    printf '%s' '{"base":{"sha":"$base"},"head":{"sha":"$HEAD_SHA"}}'
  fi
  exit 0
fi
echo "unexpected gh invocation: \$*" >&2
exit 1
EOF
  chmod +x "$STUBBIN/gh"
}

ARGV_LOG="$TMP/mra-argv.log"
# 寫 mra.sh stub。$1：要印到 stdout 的內容。$2：exit code。
write_mra_stub() {
  local out="$1" rc="${2:-0}"
  cat > "$FAKE/bin/mra.sh" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" > "$ARGV_LOG"
printf '%s' '$out'
exit $rc
EOF
  chmod +x "$FAKE/bin/mra.sh"
}

# --- 正常路徑：印出 stub 回的 JSON，退出碼 0 -------------------------------
write_gh_stub "$BASE_SHA" 0
write_mra_stub "$STUB_REVIEW_JSON" 0
out="$("$ADAPTER" review acme/rails-app-1 --pr 101 --strategy personas --json 2>"$TMP/happy.err")"
rc=$?
eq "正常路徑退出碼 0" "0" "$rc"
eq "正常路徑印出 stub 回的 JSON 原樣" "$STUB_REVIEW_JSON" "$out"

# --- owner/repo 正確拆成專案名：mra.sh 收到的是 erp，不是 acme/rails-app-1 -------
argv="$(cat "$ARGV_LOG")"
has "owner/repo 拆成專案名 erp 傳給 mra" "$argv" "review erp "
lacks "傳給 mra 的專案名不含 owner 前綴" "$argv" "acme/rails-app-1"

# --- --strategy personas --json 這些不存在的旗標不會傳給 mra --------------
lacks "不會把 --strategy 轉傳給 mra" "$argv" "--strategy"
lacks "不會把 --json 轉傳給 mra" "$argv" "--json"
has   "真正的 --personas 有被轉傳" "$argv" "--personas"
has   "轉成 --range base..head" "$argv" "--range ${BASE_SHA}..${HEAD_SHA}"

# --- 專案目錄不存在 → PROJECT_NOT_FOUND，退出碼非 0 ------------------------
out_missing="$("$ADAPTER" review acme/does-not-exist --pr 101 --strategy personas --json 2>&1 >/dev/null)"
rc_missing=$?
[[ $rc_missing -ne 0 ]] && ok "專案目錄不存在退出碼非 0" || fail "專案目錄不存在應退出非 0，得到 $rc_missing"
has "專案目錄不存在印出 PROJECT_NOT_FOUND" "$out_missing" "PROJECT_NOT_FOUND"

# --- gh 退出碼非 0 → PR_LOOKUP_FAILED(不可與下一條混報) -------------------
write_gh_stub "" 1
out_ghfail="$("$ADAPTER" review acme/rails-app-1 --pr 101 --strategy personas --json 2>&1 >/dev/null)"
rc_ghfail=$?
[[ $rc_ghfail -ne 0 ]] && ok "gh 失敗退出碼非 0" || fail "gh 失敗應退出非 0，得到 $rc_ghfail"
has   "gh 失敗印出 PR_LOOKUP_FAILED" "$out_ghfail" "PR_LOOKUP_FAILED"
lacks "gh 失敗不該印出 PR_SHA_MISSING(兩者不可混報)" "$out_ghfail" "PR_SHA_MISSING"

# --- gh 成功但 base/head 為 null → PR_SHA_MISSING ---------------------------
write_gh_stub "" 0
out_shamissing="$("$ADAPTER" review acme/rails-app-1 --pr 101 --strategy personas --json 2>&1 >/dev/null)"
rc_shamissing=$?
[[ $rc_shamissing -ne 0 ]] && ok "base/head 缺值退出碼非 0" || fail "base/head 缺值應退出非 0，得到 $rc_shamissing"
has   "base/head 缺值印出 PR_SHA_MISSING" "$out_shamissing" "PR_SHA_MISSING"
lacks "base/head 缺值不該印出 PR_LOOKUP_FAILED(兩者不可混報)" "$out_shamissing" "PR_LOOKUP_FAILED"

# --- 本地缺 commit 且 fetch 後仍缺 → COMMIT_NOT_LOCAL -----------------------
FAKE_SHA="0000000000000000000000000000000000000f"
write_gh_stub "$FAKE_SHA" 0
out_nolocal="$("$ADAPTER" review acme/rails-app-1 --pr 101 --strategy personas --json 2>&1 >/dev/null)"
rc_nolocal=$?
[[ $rc_nolocal -ne 0 ]] && ok "本地缺 commit 退出碼非 0" || fail "本地缺 commit 應退出非 0，得到 $rc_nolocal"
has "本地缺 commit 印出 COMMIT_NOT_LOCAL" "$out_nolocal" "COMMIT_NOT_LOCAL"
has "COMMIT_NOT_LOCAL 訊息指名缺的 SHA" "$out_nolocal" "$FAKE_SHA"

# --- review 指令退出碼非 0 → REVIEW_CMD_FAILED ------------------------------
write_gh_stub "$BASE_SHA" 0
write_mra_stub "" 1
out_reviewfail="$("$ADAPTER" review acme/rails-app-1 --pr 101 --strategy personas --json 2>&1 >/dev/null)"
rc_reviewfail=$?
[[ $rc_reviewfail -ne 0 ]] && ok "review 指令失敗退出碼非 0" || fail "review 指令失敗應退出非 0，得到 $rc_reviewfail"
has "review 指令失敗印出 REVIEW_CMD_FAILED" "$out_reviewfail" "REVIEW_CMD_FAILED"

# --- review 輸出不是 JSON → REVIEW_OUTPUT_INVALID ---------------------------
write_mra_stub "this is not json" 0
out_notjson="$("$ADAPTER" review acme/rails-app-1 --pr 101 --strategy personas --json 2>&1 >/dev/null)"
rc_notjson=$?
[[ $rc_notjson -ne 0 ]] && ok "review 輸出不是 JSON 退出碼非 0" || fail "應退出非 0，得到 $rc_notjson"
has "review 輸出不是 JSON 印出 REVIEW_OUTPUT_INVALID" "$out_notjson" "REVIEW_OUTPUT_INVALID"

# --- review 輸出是 JSON 但沒有 comments 鍵 → REVIEW_OUTPUT_INVALID --------
write_mra_stub '{"status":"APPROVED","summary":"x"}' 0
out_nocomments="$("$ADAPTER" review acme/rails-app-1 --pr 101 --strategy personas --json 2>&1 >/dev/null)"
rc_nocomments=$?
[[ $rc_nocomments -ne 0 ]] && ok "review 輸出缺 comments 鍵退出碼非 0" || fail "應退出非 0，得到 $rc_nocomments"
has "review 輸出缺 comments 鍵印出 REVIEW_OUTPUT_INVALID" "$out_nocomments" "REVIEW_OUTPUT_INVALID"

echo "---"; echo "Passed: $pass"; echo "Failed: $errors"
exit $((errors > 0 ? 1 : 0))
