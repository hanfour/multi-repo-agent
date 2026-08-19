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
has "轉成三點 --range base...head(不是兩點)" "$argv" "--range ${BASE_SHA}...${HEAD_SHA}"

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

# --- head 只能透過 refs/pull/<N>/head 拿到時，一般 fetch 補不到、
# 但這支腳本要能成功 ------------------------------------------------------
# 已合併的 PR，來源分支多半已經被刪掉：GitHub 對每個 PR 永遠保留
# refs/pull/<N>/head 這個 ref，但一般 `git fetch origin` 的預設 refspec
# (+refs/heads/*:refs/remotes/...)完全碰不到它。這裡用一個獨立的 bare
# 「origin」+ `git clone --no-local` 模擬真實情境：--no-local 才會強制走
# 真正的物件協商，不然 git 對同一台機器上的 clone 有個捷徑，會把整個物件庫
# 直接複製過去，讓「fetch 前 commit 就已經在本地」這件事被悄悄掩蓋掉，測試
# 會變成永遠綠燈、測不出東西。
PULLREF_DIR="$TMP/pullref"
mkdir -p "$PULLREF_DIR/ws"
BARE="$PULLREF_DIR/origin.git"
git init -q --bare "$BARE"

SRC="$PULLREF_DIR/src"
git init -q -b main "$SRC"
git -C "$SRC" config user.email t@t.t; git -C "$SRC" config user.name t
printf 'one\n' > "$SRC/f.txt"; git -C "$SRC" add f.txt; git -C "$SRC" commit -q -m base
PULLREF_BASE_SHA="$(git -C "$SRC" rev-parse HEAD)"
git -C "$SRC" remote add origin "$BARE"
git -C "$SRC" push -q origin main

# 「PR head」只推到 refs/pull/9001/head，從來不進 refs/heads/*，模擬合併後
# 來源分支被刪掉的歷史 PR。
git -C "$SRC" checkout -q -b pr-branch
printf 'two\n' >> "$SRC/f.txt"; git -C "$SRC" add f.txt; git -C "$SRC" commit -q -m head
PULLREF_HEAD_SHA="$(git -C "$SRC" rev-parse HEAD)"
git -C "$SRC" push -q origin "pr-branch:refs/pull/9001/head"
git -C "$SRC" checkout -q main

PULLREF_PROJ="$PULLREF_DIR/ws/erp"
git clone -q --no-local "$BARE" "$PULLREF_PROJ"
git -C "$PULLREF_PROJ" config user.email t@t.t; git -C "$PULLREF_PROJ" config user.name t

if git -C "$PULLREF_PROJ" cat-file -e "${PULLREF_HEAD_SHA}^{commit}" 2>/dev/null; then
  fail "測試前提不成立：clone --no-local 後 head 不該已經在本地(前提沒搭好，下面測不出東西)"
else
  ok "測試前提成立：clone --no-local 後 head 確實不在本地"
fi

cat > "$STUBBIN/gh" <<EOF
#!/usr/bin/env bash
if [[ "\$*" == *"pulls/9001"* ]]; then
  printf '%s' '{"base":{"sha":"$PULLREF_BASE_SHA"},"head":{"sha":"$PULLREF_HEAD_SHA"}}'
  exit 0
fi
echo "unexpected gh invocation: \$*" >&2
exit 1
EOF
chmod +x "$STUBBIN/gh"
write_mra_stub "$STUB_REVIEW_JSON" 0

out_pullref="$(MRA_BACKTEST_WORKSPACE="$PULLREF_DIR/ws" "$ADAPTER" review acme/rails-app-1 --pr 9001 --strategy personas --json 2>"$TMP/pullref.err")"
rc_pullref=$?
eq "head 只在 refs/pull/N/head 時退出碼仍是 0(靠 pull ref 補到)" "0" "$rc_pullref"
eq "head 只在 refs/pull/N/head 時仍印出 stub JSON 原樣" "$STUB_REVIEW_JSON" "$out_pullref"
lacks "head 只在 refs/pull/N/head 時不該印出 COMMIT_NOT_LOCAL" "$(cat "$TMP/pullref.err")" "COMMIT_NOT_LOCAL"
if git -C "$PULLREF_PROJ" cat-file -e "${PULLREF_HEAD_SHA}^{commit}" 2>/dev/null; then
  ok "adapter 執行後 head 確實已經 fetch 進本地(pull ref 生效)"
else
  fail "adapter 執行後 head 仍然不在本地，pull ref fetch 沒有生效"
fi

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

# --- MRA_BACKTEST_REVIEW_MODE：兩種設定各自傳出正確的 argv ------------------
write_gh_stub "$BASE_SHA" 0
write_mra_stub "$STUB_REVIEW_JSON" 0

# 明講 personas(不是只測預設值)：跟不設這個 env 時應該傳出同樣的旗標。
out_mode_personas="$(MRA_BACKTEST_REVIEW_MODE=personas "$ADAPTER" review acme/rails-app-1 --pr 101 --strategy personas --json 2>"$TMP/mode-personas.err")"
rc_mode_personas=$?
eq "MRA_BACKTEST_REVIEW_MODE=personas 退出碼 0" "0" "$rc_mode_personas"
eq "MRA_BACKTEST_REVIEW_MODE=personas 印出 stub JSON 原樣" "$STUB_REVIEW_JSON" "$out_mode_personas"
argv_personas="$(cat "$ARGV_LOG")"
has   "personas 模式傳 --personas 給 mra" "$argv_personas" "--personas"
lacks "personas 模式不傳 --strategy 給 mra" "$argv_personas" "--strategy"
lacks "personas 模式不傳 --provider 給 mra" "$argv_personas" "--provider"

out_mode_standard="$(MRA_BACKTEST_REVIEW_MODE=standard "$ADAPTER" review acme/rails-app-1 --pr 101 --strategy personas --json 2>"$TMP/mode-standard.err")"
rc_mode_standard=$?
eq "MRA_BACKTEST_REVIEW_MODE=standard 退出碼 0" "0" "$rc_mode_standard"
eq "MRA_BACKTEST_REVIEW_MODE=standard 印出 stub JSON 原樣" "$STUB_REVIEW_JSON" "$out_mode_standard"
argv_standard="$(cat "$ARGV_LOG")"
has   "standard 模式傳 --strategy standard 給 mra" "$argv_standard" "--strategy standard"
has   "standard 模式傳 --provider codex 給 mra" "$argv_standard" "--provider codex"
lacks "standard 模式不傳 --personas 給 mra" "$argv_standard" "--personas"

# --- 不認得的 MRA_BACKTEST_REVIEW_MODE 值要報錯退出，不能默默 fallback -----
rm -f "$ARGV_LOG"
out_mode_invalid="$(MRA_BACKTEST_REVIEW_MODE=presonas "$ADAPTER" review acme/rails-app-1 --pr 101 --strategy personas --json 2>&1 >/dev/null)"
rc_mode_invalid=$?
[[ $rc_mode_invalid -ne 0 ]] && ok "不認得的 REVIEW_MODE 退出碼非 0" || fail "不認得的 REVIEW_MODE 應退出非 0，得到 $rc_mode_invalid"
has "不認得的 REVIEW_MODE 印出 REVIEW_MODE_INVALID" "$out_mode_invalid" "REVIEW_MODE_INVALID"
has "REVIEW_MODE_INVALID 訊息指名打錯的值" "$out_mode_invalid" "presonas"
if [[ -e "$ARGV_LOG" ]]; then
  fail "不認得的 REVIEW_MODE 不該走到呼叫 mra 那一步(該在最前面就先擋下來)"
else
  ok "不認得的 REVIEW_MODE 在呼叫 gh／mra 之前就先擋下來(fail fast)"
fi

echo "---"; echo "Passed: $pass"; echo "Failed: $errors"
exit $((errors > 0 ? 1 : 0))
