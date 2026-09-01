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
# macOS 的 $TMPDIR 常帶結尾斜線，讓 mktemp 出來的路徑含一個多餘的雙斜線；
# 子行程裡 `cd ... && pwd` 印出來的是 shell 正規化過的單斜線版本。這裡先
# 正規化一次，後面所有拿 $TMP 組出來的路徑（包含要去比對 stub 印出的 pwd
# 那幾條斷言）才會跟子行程看到的字串逐位元組一致。
TMP="$(cd "$TMP" && pwd)"
trap 'rm -rf "$TMP"' EXIT

FAKE="$TMP/fake"
mkdir -p "$FAKE/scripts" "$FAKE/bin"
ln -s "$REAL_ADAPTER" "$FAKE/scripts/backtest-review-adapter.sh"
ADAPTER="$FAKE/scripts/backtest-review-adapter.sh"

# adapter 會從 $MRA_DIR/config.json 衍生一份只改 codex model 與 reasoning
# effort 的回測設定。真實的 MRA_DIR 一定有這個檔(在版控內)，假的專案樹要自己
# 補一份，形狀跟真的一致即可。
cat > "$FAKE/config.json" <<'FAKECFG'
{
  "review": {
    "providerMode": "codex",
    "models": { "claude": "sonnet", "codex": "gpt-5.6-luna" },
    "codexReasoningEffort": "max"
  }
}
FAKECFG

# gh 是裸命令查找，用 PATH 前置一個 stub 目錄就能接住。
STUBBIN="$TMP/stubbin"
mkdir -p "$STUBBIN"
export PATH="$STUBBIN:$PATH"

WS="$TMP/ws"
mkdir -p "$WS/.collab"
export MRA_BACKTEST_WORKSPACE="$WS"

# worktree 隔離的平行 workspace 根目錄：固定指到這支測試自己的 $TMP 底下，
# 不用預設值(${TMPDIR:-/tmp}/mra-backtest-ws)。預設值是系統共用路徑，測試
# 用它會跟真的跑一次基準線互相污染，也不會隨這支測試的 $TMP 一起被清掉。
WT_ROOT="$TMP/wtroot"
export MRA_BACKTEST_WT_ROOT="$WT_ROOT"

# workspace 層 metadata：只有這三個檔會被複製，manual-deps.json 故意不建，
# 用來驗證「存在才複製，缺了不算錯」。
echo '{"repos":"stub"}' > "$WS/.collab/repos.json"
echo '{"deps":"stub"}' > "$WS/.collab/dep-graph.json"

R="$WS/rails-app-1"
git -C "$R" init -q -b main 2>/dev/null || { mkdir -p "$R"; git -C "$R" init -q -b main; }
git -C "$R" config user.email t@t.t; git -C "$R" config user.name t
printf 'one\n' > "$R/f.txt"; git -C "$R" add f.txt; git -C "$R" commit -q -m base
BASE_SHA="$(git -C "$R" rev-parse HEAD)"
printf 'two\n' >> "$R/f.txt"; git -C "$R" add f.txt; git -C "$R" commit -q -m head
HEAD_SHA="$(git -C "$R" rev-parse HEAD)"

# 模擬使用者手邊正在做的事(真實情境：~/workspace/rails-app-1 checkout 在
# feature/account-management-with-estimates，有未提交的變更)：repo 目前
# checkout 在 head_sha 之後的另一個 commit，還有未提交的變更。worktree
# 隔離全程都不能碰這些，這支測試檔案的其他一切斷言(包含既有的)都要在這個
# 前提還成立的狀態下通過，才能證明真的沒被動到。
printf 'three\n' >> "$R/f.txt"; git -C "$R" add f.txt; git -C "$R" commit -q -m "later work in progress"
ORIG_HEAD_SHA="$(git -C "$R" rev-parse HEAD)"
printf 'uncommitted change\n' >> "$R/f.txt"
printf 'another uncommitted file\n' > "$R/g.txt"
ORIG_STATUS_LINES="$(git -C "$R" status --porcelain | wc -l | tr -d ' ')"

# PKB：真實 repo 裡 .mra 被 gitignore，worktree 不會自動有，要驗證這裡的
# 內容真的被實體複製過去（不是 symlink）。
#
# 這個 repo 自己要寫一次排除規則，不能靠開發者的全域 gitignore。.mra 是在
# ORIG_STATUS_LINES 取完之後才建的，沒有排除規則的話它會是第三筆未追蹤變更，
# 檔案最後那條「來源 repo 未提交變更的筆數全程沒有被動過」就會 2 對 3 而紅。
# 我的機器上 ~/.config/git/ignore 有 .mra/，所以一直是綠的；CI 的 Linux runner
# 沒有，所以一直是紅的。測試的前提要寫在測試裡，靠環境提供的前提等於沒有前提。
printf '.mra/\n' >> "$R/.git/info/exclude"
mkdir -p "$R/.mra/pkb"
echo '{"convention":"stub"}' > "$R/.mra/pkb/example.json"

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
# MRA_REVIEW_AGENT_MAX_TURNS 是環境變數，不會出現在 $*(argv)裡，argv 紀錄檔
# 驗不到「adapter 有沒有設這個 env」，另外開一個檔案專門記它。
ENV_LOG="$TMP/mra-env.log"
# worktree 相關的狀態要在 stub 執行的當下(worktree 還活著)就記下來：adapter
# 執行完之後 worktree 會被清掉，事後才檢查會什麼都看不到。$project 是相對
# 於 stub 自己 cwd(應該是 $BT_WS)的子目錄，等於 stub 自己站在 worktree 隔離
# 之後的那個目錄裡，直接查看得到的東西就是 mra review 實際看到的東西。
WT_LOG="$TMP/mra-wt.log"
# 寫 mra.sh stub。$1：要印到 stdout 的內容。$2：exit code。
write_mra_stub() {
  local out="$1" rc="${2:-0}"
  cat > "$FAKE/bin/mra.sh" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" > "$ARGV_LOG"
printf 'MRA_REVIEW_AGENT_MAX_TURNS=%s\n' "\${MRA_REVIEW_AGENT_MAX_TURNS:-<unset>}" > "$ENV_LOG"
printf 'MRA_CONFIG=%s\n' "\${MRA_CONFIG:-<unset>}" >> "$ENV_LOG"
printf 'MRA_REVIEW_PERSONA_DUMP_DIR=%s\n' "\${MRA_REVIEW_PERSONA_DUMP_DIR:-<unset>}" >> "$ENV_LOG"
{
  printf 'cwd=%s\n' "\$(pwd)"
  printf 'worktree_head=%s\n' "\$(git -C rails-app-1 rev-parse HEAD 2>&1)"
  printf 'collab_files=%s\n' "\$(ls .collab 2>&1 | tr '\n' ',')"
  if [[ -L rails-app-1/.mra ]]; then
    printf 'mra_dir=SYMLINK\n'
  elif [[ -d rails-app-1/.mra ]]; then
    printf 'mra_dir=REALDIR\n'
  else
    printf 'mra_dir=MISSING\n'
  fi
  printf 'mra_pkb_files=%s\n' "\$(ls rails-app-1/.mra/pkb 2>&1 | tr '\n' ',')"
} > "$WT_LOG"
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

# --- worktree 隔離：mra 實際看到的是 worktree 那份，不是共用工作目錄 -------
wt_log="$(cat "$WT_LOG")"
has "mra 執行時的 cwd 是平行 workspace($WT_ROOT)，不是 \$WS" "$wt_log" "cwd=$WT_ROOT"
has "worktree checkout 的是 PR head_sha" "$wt_log" "worktree_head=$HEAD_SHA"
lacks "worktree checkout 的不是共用工作目錄目前的分支頭(later work in progress 那個 commit)" \
  "$wt_log" "worktree_head=$ORIG_HEAD_SHA"
has ".collab 的 repos.json 有被複製過去" "$wt_log" "repos.json"
has ".collab 的 dep-graph.json 有被複製過去" "$wt_log" "dep-graph.json"
lacks ".collab 沒有 manual-deps.json(來源本來就沒有，缺了不算錯)" \
  "$wt_log" "manual-deps.json"
has ".mra 是實體目錄，不是 symlink" "$wt_log" "mra_dir=REALDIR"
has ".mra/pkb 底下的內容真的被複製過去" "$wt_log" "example.json"

# --- 跑完之後 worktree 被移除，git worktree list 回到原本的筆數 -----------
wt_count_after_happy="$(git -C "$R" worktree list | wc -l | tr -d ' ')"
eq "正常路徑跑完後 git worktree list 只剩來源 repo 自己(1 筆)" "1" "$wt_count_after_happy"

# --- owner/repo 正確拆成專案名：mra.sh 收到的是 rails-app-1，不是 acme/rails-app-1 -------
argv="$(cat "$ARGV_LOG")"
has "owner/repo 拆成專案名 rails-app-1 傳給 mra" "$argv" "review rails-app-1 "
lacks "傳給 mra 的專案名不含 owner 前綴" "$argv" "acme/rails-app-1"

# --- --strategy personas --json 這些不存在的旗標不會傳給 mra --------------
lacks "不會把 --strategy 轉傳給 mra" "$argv" "--strategy"
lacks "不會把 --json 轉傳給 mra" "$argv" "--json"
has   "真正的 --personas 有被轉傳" "$argv" "--personas"
has "轉成三點 --range base...head(不是兩點)" "$argv" "--range ${BASE_SHA}...${HEAD_SHA}"

# --- MRA_REVIEW_AGENT_MAX_TURNS：預設補 40(對齊 ~/.pmk 的 gateway 設定) ---
has "呼叫端沒設時，adapter 幫忙補 MRA_REVIEW_AGENT_MAX_TURNS=40" \
  "$(cat "$ENV_LOG")" "MRA_REVIEW_AGENT_MAX_TURNS=40"

# --- 呼叫端已經設過的話，adapter 不覆蓋(操作者設的值要贏) ------------------
rm -f "$ENV_LOG"
out_turns_override="$(MRA_REVIEW_AGENT_MAX_TURNS=99 "$ADAPTER" review acme/rails-app-1 --pr 101 --strategy personas --json 2>"$TMP/turns-override.err")"
rc_turns_override=$?
eq "呼叫端已設 MRA_REVIEW_AGENT_MAX_TURNS 時退出碼仍是 0" "0" "$rc_turns_override"
eq "呼叫端已設 MRA_REVIEW_AGENT_MAX_TURNS 時仍印出 stub JSON 原樣" \
  "$STUB_REVIEW_JSON" "$out_turns_override"
has "呼叫端已設 MRA_REVIEW_AGENT_MAX_TURNS=99 時 adapter 不覆蓋，mra 收到 99" \
  "$(cat "$ENV_LOG")" "MRA_REVIEW_AGENT_MAX_TURNS=99"

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

PULLREF_PROJ="$PULLREF_DIR/ws/rails-app-1"
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

# review 失敗(這支 adapter 自己判定為失敗，退出非 0)時 worktree 也要被清掉，
# 不能只在成功路徑才清：trap 綁的是 EXIT，不是「成功才清」。
wt_count_after_failed_review="$(git -C "$R" worktree list | wc -l | tr -d ' ')"
eq "review 指令失敗時 worktree 依然被清掉(回到 1 筆)" "1" "$wt_count_after_failed_review"

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

# --- standard 模式的衍生 config：改 models.codex／codexReasoningEffort，
# providerMode 不被改動 -------------------------------------------------------
# config.json 的 review.models.codex 是共用設定（在版控內），回測不改它，
# 從共用設定衍生一份副本，用 MRA_CONFIG 指過去。
cfg_dir="$TMP/derived"; mkdir -p "$cfg_dir"
out_cfg="$(MRA_BACKTEST_REVIEW_MODE=standard MRA_BACKTEST_CONFIG_DIR="$cfg_dir" \
  "$ADAPTER" review acme/rails-app-1 --pr 101 --strategy personas --json 2>"$TMP/cfg.err")"
rc_cfg=$?
eq "產生衍生設定時退出碼 0" "0" "$rc_cfg"
eq "產生衍生設定時仍印出 stub JSON 原樣" "$STUB_REVIEW_JSON" "$out_cfg"
derived="$cfg_dir/mra-backtest-config.json"
if [[ -s "$derived" ]]; then ok "衍生設定檔有寫出來"; else fail "衍生設定檔沒寫出來：$derived"; fi
eq "standard 模式：衍生設定的 codex model 是 gpt-5.5" "gpt-5.5" \
  "$(jq -r '.review.models.codex' "$derived" 2>/dev/null)"
eq "standard 模式：衍生設定的 reasoning effort 是 xhigh" "xhigh" \
  "$(jq -r '.review.codexReasoningEffort' "$derived" 2>/dev/null)"
eq "standard 模式：providerMode 不被改動，維持共用設定的原值 codex" "codex" \
  "$(jq -r '.review.providerMode' "$derived" 2>/dev/null)"
eq "來源 config.json 沒有被改動" "gpt-5.6-luna" \
  "$(jq -r '.review.models.codex' "$FAKE/config.json" 2>/dev/null)"

# 上面那條斷言只驗「值剛好是 codex」，驗不出「這個值到底是被程式碼動過還是
# 本來就沒被動」。共用設定裡 providerMode 本來就是 codex，就算 standard
# 模式的衍生邏輯手滑寫死 providerMode = "codex"，這條斷言照樣會過，測不出
# 差異。這裡把來源設定的 providerMode 暫時改成一個真實情況不會出現的值，
# 驗證 standard 模式衍生完之後這個怪值原封不動地留著，證明程式碼真的完全
# 沒碰這個鍵，不是巧合對上同一個值。驗完要把 $FAKE/config.json 換回來，
# 後面其他斷言都依賴它維持原本內容。
orig_fake_config="$(cat "$FAKE/config.json")"
jq '.review.providerMode = "sentinel-untouched-marker"' "$FAKE/config.json" > "$TMP/fake-config-sentinel.json"
mv "$TMP/fake-config-sentinel.json" "$FAKE/config.json"
rm -f "$cfg_dir/mra-backtest-config.json"
MRA_BACKTEST_REVIEW_MODE=standard MRA_BACKTEST_CONFIG_DIR="$cfg_dir" \
  "$ADAPTER" review acme/rails-app-1 --pr 101 --strategy personas --json >/dev/null 2>&1
eq "standard 模式真的完全沒碰 providerMode 這個鍵(不是剛好都是 codex)" \
  "sentinel-untouched-marker" "$(jq -r '.review.providerMode' "$derived" 2>/dev/null)"
printf '%s' "$orig_fake_config" > "$FAKE/config.json"
# 只檢查衍生檔的內容不夠：export 掉了的話 mra 仍讀共用設定，機制整個失效而
# 測試照樣綠。這一條斷言 mra 真的收到指向衍生檔的 MRA_CONFIG。
has "mra 收到指向衍生設定的 MRA_CONFIG" "$(cat "$ENV_LOG")" "MRA_CONFIG=$derived"

# --- personas 模式的衍生 config：改 providerMode／models.claude，
# models.codex／codexReasoningEffort 維持來源檔原值，不被動 -----------------
# 這是這一輪要修的核心：上一版只改 models.codex，但 personas／debate 底下
# 個別 agent 呼叫預設走 claude(lib/review-personas.sh:59)，共用
# providerMode 又是 codex，解析出來的 model 名稱被送去給 claude，claude
# 不認得那個名字，整批失敗(實測：claude failed: "gpt-5.5" is not a model
# this version of Claude Code recognizes)。
PCFG_DIR="$TMP/derived-personas"; mkdir -p "$PCFG_DIR"
out_pcfg="$(MRA_BACKTEST_CONFIG_DIR="$PCFG_DIR" \
  "$ADAPTER" review acme/rails-app-1 --pr 101 --strategy personas --json 2>"$TMP/pcfg.err")"
rc_pcfg=$?
eq "personas 模式產生衍生設定時退出碼 0" "0" "$rc_pcfg"
eq "personas 模式產生衍生設定時仍印出 stub JSON 原樣" "$STUB_REVIEW_JSON" "$out_pcfg"
pderived="$PCFG_DIR/mra-backtest-config.json"
if [[ -s "$pderived" ]]; then
  ok "personas 模式衍生設定檔有寫出來"
else
  fail "personas 模式衍生設定檔沒寫出來：$pderived"
fi
eq "personas 模式：providerMode 被改成 claude" "claude" \
  "$(jq -r '.review.providerMode' "$pderived" 2>/dev/null)"
eq "personas 模式：models.claude 是預設值 sonnet" "sonnet" \
  "$(jq -r '.review.models.claude' "$pderived" 2>/dev/null)"
eq "personas 模式：models.codex 維持來源檔原值，沒被動過" "gpt-5.6-luna" \
  "$(jq -r '.review.models.codex' "$pderived" 2>/dev/null)"
eq "personas 模式：codexReasoningEffort 維持來源檔原值，沒被動過" "max" \
  "$(jq -r '.review.codexReasoningEffort' "$pderived" 2>/dev/null)"

# --- MRA_BACKTEST_CLAUDE_MODEL 可覆蓋 personas 模式的預設 model -----------
PCFG_DIR2="$TMP/derived-personas-2"; mkdir -p "$PCFG_DIR2"
MRA_BACKTEST_CONFIG_DIR="$PCFG_DIR2" MRA_BACKTEST_CLAUDE_MODEL=opus \
  "$ADAPTER" review acme/rails-app-1 --pr 101 --strategy personas --json >/dev/null 2>&1
eq "MRA_BACKTEST_CLAUDE_MODEL 會覆蓋預設值" "opus" \
  "$(jq -r '.review.models.claude' "$PCFG_DIR2/mra-backtest-config.json" 2>/dev/null)"

# --- 呼叫端自己指定 MRA_CONFIG 時，adapter 不覆蓋 --------------------------
rm -f "$ENV_LOG"
caller_cfg="$TMP/caller-config.json"
cp "$FAKE/config.json" "$caller_cfg"
out_cfg_caller="$(MRA_BACKTEST_REVIEW_MODE=standard MRA_CONFIG="$caller_cfg" \
  "$ADAPTER" review acme/rails-app-1 --pr 101 --strategy personas --json 2>"$TMP/cfg-caller.err")"
rc_cfg_caller=$?
eq "呼叫端指定 MRA_CONFIG 時退出碼 0" "0" "$rc_cfg_caller"
eq "呼叫端指定 MRA_CONFIG 時仍印出 stub JSON 原樣" "$STUB_REVIEW_JSON" "$out_cfg_caller"
has "呼叫端指定的 MRA_CONFIG 不被覆蓋" "$(cat "$ENV_LOG")" "MRA_CONFIG=$caller_cfg"

out_cfg2="$(MRA_BACKTEST_REVIEW_MODE=standard MRA_BACKTEST_CONFIG_DIR="$cfg_dir" \
  MRA_BACKTEST_CODEX_MODEL=gpt-4.9 MRA_BACKTEST_CODEX_EFFORT=high \
  "$ADAPTER" review acme/rails-app-1 --pr 101 --strategy personas --json 2>"$TMP/cfg2.err")"
eq "覆蓋 model／effort 時仍印出 stub JSON 原樣" "$STUB_REVIEW_JSON" "$out_cfg2"
eq "MRA_BACKTEST_CODEX_MODEL 會覆蓋預設值" "gpt-4.9" \
  "$(jq -r '.review.models.codex' "$derived" 2>/dev/null)"
eq "MRA_BACKTEST_CODEX_EFFORT 會覆蓋預設值" "high" \
  "$(jq -r '.review.codexReasoningEffort' "$derived" 2>/dev/null)"

# --- adapter 有寫出執行條件回報檔(cond 檔)，內容是它實際用的值 ------------
# run-backtest.sh 是呼叫端，看不到這裡衍生出來的設定；adapter 才是唯一
# 知道「這次實際用了什麼」的地方，MRA_BACKTEST_COND_FILE 有設時要主動
# 回報，不能讓呼叫端自己去猜(猜過一次，猜錯了)。欄位原本叫 codex_model，
# personas 模式跑的是 claude，填進一個叫 codex_model 的鍵本身就是錯的值，
# 跟這一輪要修的問題同一類，改名成 model，另外加一個 provider 欄位。
COND_FILE_TEST="$TMP/run-conditions-test.json"
rm -f "$COND_FILE_TEST"
write_gh_stub "$BASE_SHA" 0
write_mra_stub "$STUB_REVIEW_JSON" 0
out_cond="$(MRA_BACKTEST_REVIEW_MODE=standard MRA_BACKTEST_CONFIG_DIR="$cfg_dir" \
  MRA_BACKTEST_CODEX_MODEL=gpt-cond-test MRA_BACKTEST_CODEX_EFFORT=super \
  MRA_BACKTEST_COND_FILE="$COND_FILE_TEST" \
  "$ADAPTER" review acme/rails-app-1 --pr 101 --strategy personas --json 2>"$TMP/cond.err")"
rc_cond=$?
eq "設了 MRA_BACKTEST_COND_FILE 時退出碼仍是 0" "0" "$rc_cond"
eq "設了 MRA_BACKTEST_COND_FILE 時仍印出 stub JSON 原樣" "$STUB_REVIEW_JSON" "$out_cond"
if [[ -s "$COND_FILE_TEST" ]]; then
  ok "adapter 有寫出 cond 檔"
else
  fail "cond 檔沒有被寫出來：$COND_FILE_TEST"
fi
eq "standard 模式 cond 檔的 model 是這次實際用的值(不是預設的 gpt-5.5)" \
  "gpt-cond-test" "$(jq -r '.model' "$COND_FILE_TEST")"
eq "standard 模式 cond 檔的 provider 是 codex" "codex" \
  "$(jq -r '.provider' "$COND_FILE_TEST")"
eq "standard 模式 cond 檔的 reasoning_effort 是這次實際用的值" "super" \
  "$(jq -r '.reasoning_effort' "$COND_FILE_TEST")"
eq "cond 檔的 review_mode 是這次實際用的值(standard)" "standard" \
  "$(jq -r '.review_mode' "$COND_FILE_TEST")"
# max_turns 記的是 standard 模式實際生效的上限(MRA_REVIEW_STANDARD_MAX_TURNS，
# 預設 6)，不是只影響 debate 路徑的 MRA_REVIEW_AGENT_MAX_TURNS(預設 40)：
# 跟先前 codex_model 那次同一類，記錯的值比沒有欄位更糟。
eq "standard 模式 cond 檔的 max_turns 是 MRA_REVIEW_STANDARD_MAX_TURNS 的預設值 6(不是 40)" \
  "6" "$(jq -r '.max_turns' "$COND_FILE_TEST")"
eq "standard 模式沒有 synthesize 這一步，synth_max_turns 是 JSON null" \
  "null" "$(jq -e '.synth_max_turns' "$COND_FILE_TEST")"
eq "cond 檔的 worktree_isolated 是 adapter 自己回報的 true(隔離就是它做的)" \
  "true" "$(jq -r '.worktree_isolated' "$COND_FILE_TEST")"
eq "cond 檔的 mra_config_path 指到這次真正衍生出來的設定檔" "$derived" \
  "$(jq -r '.mra_config_path' "$COND_FILE_TEST")"

# --- MRA_REVIEW_STANDARD_MAX_TURNS 可覆蓋，cond 檔跟著換 -------------------
rm -f "$COND_FILE_TEST"
MRA_BACKTEST_REVIEW_MODE=standard MRA_BACKTEST_CONFIG_DIR="$cfg_dir" \
  MRA_REVIEW_STANDARD_MAX_TURNS=12 MRA_BACKTEST_COND_FILE="$COND_FILE_TEST" \
  "$ADAPTER" review acme/rails-app-1 --pr 101 --strategy personas --json >/dev/null 2>&1
eq "設了 MRA_REVIEW_STANDARD_MAX_TURNS=12 時，cond 檔的 max_turns 跟著變" \
  "12" "$(jq -r '.max_turns' "$COND_FILE_TEST")"

# 換個 model 重跑，驗證 cond 檔內容真的跟著換，不是釘死或殘留的舊值。
rm -f "$COND_FILE_TEST"
MRA_BACKTEST_REVIEW_MODE=standard MRA_BACKTEST_CONFIG_DIR="$cfg_dir" \
  MRA_BACKTEST_CODEX_MODEL=gpt-cond-test-2 MRA_BACKTEST_CODEX_EFFORT=super \
  MRA_BACKTEST_COND_FILE="$COND_FILE_TEST" \
  "$ADAPTER" review acme/rails-app-1 --pr 101 --strategy personas --json >/dev/null 2>&1
eq "換 MRA_BACKTEST_CODEX_MODEL 重跑後，cond 檔內容跟著變" "gpt-cond-test-2" \
  "$(jq -r '.model' "$COND_FILE_TEST")"

# --- personas 模式的 cond 檔：provider／model 是 claude／sonnet，
# reasoning_effort 是 JSON null，不是空字串也不是省略這個鍵 -----------------
PCOND_FILE_TEST="$TMP/run-conditions-personas-test.json"
rm -f "$PCOND_FILE_TEST"
MRA_BACKTEST_CONFIG_DIR="$PCFG_DIR" MRA_BACKTEST_COND_FILE="$PCOND_FILE_TEST" \
  "$ADAPTER" review acme/rails-app-1 --pr 101 --strategy personas --json >/dev/null 2>&1
eq "personas 模式 cond 檔的 provider 是 claude" "claude" \
  "$(jq -r '.provider' "$PCOND_FILE_TEST")"
eq "personas 模式 cond 檔的 model 是 sonnet" "sonnet" \
  "$(jq -r '.model' "$PCOND_FILE_TEST")"
eq "personas 模式 cond 檔的 reasoning_effort 是 JSON null(不是字串、不是省略)" \
  "null" "$(jq -e '.reasoning_effort' "$PCOND_FILE_TEST")"
# max_turns 記的是 personas 模式實際生效的上限(MRA_REVIEW_PERSONA_MAX_TURNS，
# 預設 8)。synth_max_turns 是 personas 模式 synthesize 這一步的上限
# (MRA_REVIEW_SYNTH_MAX_TURNS，預設 8，上一輪才讓它可調)，是數字，不是 null
# (只有 standard 模式才是 null，personas 模式一定有 synthesize 這一步)。
eq "personas 模式 cond 檔的 max_turns 是 MRA_REVIEW_PERSONA_MAX_TURNS 的預設值 8" \
  "8" "$(jq -r '.max_turns' "$PCOND_FILE_TEST")"
eq "personas 模式 cond 檔的 synth_max_turns 是 MRA_REVIEW_SYNTH_MAX_TURNS 的預設值 8(是數字，不是 null)" \
  "8" "$(jq -r '.synth_max_turns' "$PCOND_FILE_TEST")"

# --- MRA_REVIEW_PERSONA_MAX_TURNS／MRA_REVIEW_SYNTH_MAX_TURNS 可各自覆蓋，
#     cond 檔跟著換，不是釘死或殘留的舊值 --------------------------------
PCOND_FILE_TEST2="$TMP/run-conditions-personas-test2.json"
rm -f "$PCOND_FILE_TEST2"
MRA_BACKTEST_CONFIG_DIR="$PCFG_DIR" MRA_BACKTEST_COND_FILE="$PCOND_FILE_TEST2" \
  MRA_REVIEW_PERSONA_MAX_TURNS=15 MRA_REVIEW_SYNTH_MAX_TURNS=20 \
  "$ADAPTER" review acme/rails-app-1 --pr 101 --strategy personas --json >/dev/null 2>&1
eq "設了 MRA_REVIEW_PERSONA_MAX_TURNS=15 時，cond 檔的 max_turns 跟著變" \
  "15" "$(jq -r '.max_turns' "$PCOND_FILE_TEST2")"
eq "設了 MRA_REVIEW_SYNTH_MAX_TURNS=20 時，cond 檔的 synth_max_turns 跟著變" \
  "20" "$(jq -r '.synth_max_turns' "$PCOND_FILE_TEST2")"

# --- MRA_BACKTEST_PERSONA_DUMP_BASE：每個 PR 自己一個子目錄 ----------------
# persona 的原始輸出是唯一能分辨「這個 persona 根本沒提到這個檔案」與
# 「提到了、但 synthesize 把它丟掉」的東西，最終 JSON 兩者長得一樣。
# 一輪回測跑 38 個 PR，所以 dump 目錄一定要逐 PR 分開，否則後跑的 PR 會
# 蓋掉先跑的，留下來的只有最後一個 PR 的輸出。
"$ADAPTER" review acme/rails-app-1 --pr 101 --strategy personas --json >/dev/null 2>&1
eq "沒設 MRA_BACKTEST_PERSONA_DUMP_BASE 時，不傳 MRA_REVIEW_PERSONA_DUMP_DIR 給 mra review" \
  "<unset>" "$(grep '^MRA_REVIEW_PERSONA_DUMP_DIR=' "$ENV_LOG" | cut -d= -f2-)"

DUMP_BASE="$TMP/persona-dumps"
MRA_BACKTEST_PERSONA_DUMP_BASE="$DUMP_BASE" \
  "$ADAPTER" review acme/rails-app-1 --pr 101 --strategy personas --json >/dev/null 2>&1
# 路徑裡同時含 repo 與 pr，逐 PR 分開這件事就成立了（gh stub 只認 101，
# 沒辦法在這裡真的跑第二個 PR 來對照）。
eq "設了 MRA_BACKTEST_PERSONA_DUMP_BASE 時，per-PR 子目錄用 <repo 的斜線換成雙底線>__<pr>" \
  "$DUMP_BASE/acme__rails-app-1__101" \
  "$(grep '^MRA_REVIEW_PERSONA_DUMP_DIR=' "$ENV_LOG" | cut -d= -f2-)"

# --- MRA_BACKTEST_COND_FILE 沒設時，adapter 不寫檔也不報錯 -----------------
out_nocond="$("$ADAPTER" review acme/rails-app-1 --pr 101 --strategy personas --json 2>"$TMP/nocond.err")"
rc_nocond=$?
eq "沒設 MRA_BACKTEST_COND_FILE 時退出碼仍是 0" "0" "$rc_nocond"
eq "沒設 MRA_BACKTEST_COND_FILE 時仍印出 stub JSON 原樣" "$STUB_REVIEW_JSON" "$out_nocond"
lacks "沒設 MRA_BACKTEST_COND_FILE 時不該印出 COND_FILE_WRITE_FAILED" \
  "$(cat "$TMP/nocond.err")" "COND_FILE_WRITE_FAILED"

# --- cond 檔寫入失敗時，adapter 的退出碼不變、review 輸出照常 --------------
# 寫檔失敗只是記錄失敗，不該讓一次成功的 review 變成回報失敗，比照
# WORKTREE_CLEANUP_FAILED 那組斷言的精神：只印警告到 stderr。
COND_DIR_RO="$TMP/cond-readonly"
mkdir -p "$COND_DIR_RO"
chmod 555 "$COND_DIR_RO"
out_condfail="$(MRA_BACKTEST_COND_FILE="$COND_DIR_RO/run-conditions.json" \
  "$ADAPTER" review acme/rails-app-1 --pr 101 --strategy personas --json 2>"$TMP/condfail.err")"
rc_condfail=$?
chmod 755 "$COND_DIR_RO"
eq "cond 檔目錄唯讀時退出碼仍是 0(寫入失敗不該讓成功的 review 變失敗)" \
  "0" "$rc_condfail"
eq "cond 檔目錄唯讀時仍印出 stub JSON 原樣" "$STUB_REVIEW_JSON" "$out_condfail"
has "cond 檔寫入失敗有印出 COND_FILE_WRITE_FAILED 警告" \
  "$(cat "$TMP/condfail.err")" "COND_FILE_WRITE_FAILED"

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

# --- 同路徑有殘留 worktree 時能自救：先清再建，不是直接失敗 ----------------
# 手動先在目標路徑建一個「殘留」worktree(checkout 在 base_sha，不是這次要
# 用的 head_sha，才能明確驗出最後拿到的是重建過的、checkout 在 head_sha 的
# 那一份，不是殘留的舊版)，模擬前一次跑到一半被中斷、trap 沒機會清乾淨的
# 情況。
WT_TARGET="$WT_ROOT/rails-app-1"
git -C "$R" worktree add --detach "$WT_TARGET" "$BASE_SHA" >/dev/null 2>&1
if git -C "$R" worktree list | grep -qF "$WT_TARGET"; then
  ok "測試前提成立：目標路徑已經有一個殘留 worktree(checkout 在 base_sha)"
else
  fail "測試前提不成立：沒能先建出殘留 worktree，下面測不出自救"
fi

write_gh_stub "$BASE_SHA" 0
write_mra_stub "$STUB_REVIEW_JSON" 0
out_rescue="$("$ADAPTER" review acme/rails-app-1 --pr 101 --strategy personas --json 2>"$TMP/rescue.err")"
rc_rescue=$?
eq "同路徑有殘留 worktree 時 adapter 仍能成功(自救，不是直接失敗)" "0" "$rc_rescue"
eq "自救後仍印出 stub JSON 原樣" "$STUB_REVIEW_JSON" "$out_rescue"
has "自救後 worktree checkout 的是這次真正要的 head_sha(不是殘留的 base_sha)" \
  "$(cat "$WT_LOG")" "worktree_head=$HEAD_SHA"
wt_count_after_rescue="$(git -C "$R" worktree list | wc -l | tr -d ' ')"
eq "自救流程跑完後 worktree 一樣被清乾淨(回到 1 筆)" "1" "$wt_count_after_rescue"

# --- git worktree add 本身失敗 → WORKTREE_ADD_FAILED，退出非 0 -------------
# 把來源 repo 的 .git 改成唯讀，讓 `git worktree add` 寫自己的
# .git/worktrees/<name> 記錄這一步失敗(worktree add 需要在來源 repo 的 .git
# 底下建新的管理目錄)。這個技巧不會動到 $BT_WS，跟 metadata 複製那幾步互不
# 干擾，乾淨地只讓 worktree add 這一步失敗。
chmod -R 555 "$R/.git"
out_wtaddfail="$("$ADAPTER" review acme/rails-app-1 --pr 101 --strategy personas --json 2>&1 >/dev/null)"
rc_wtaddfail=$?
chmod -R 755 "$R/.git"
[[ $rc_wtaddfail -ne 0 ]] && ok "worktree add 失敗時退出碼非 0" \
                          || fail "worktree add 失敗應退出非 0，得到 $rc_wtaddfail"
has "worktree add 失敗印出 WORKTREE_ADD_FAILED" "$out_wtaddfail" "WORKTREE_ADD_FAILED"

# --- 來源沒有 .mra 時不算錯，review 照樣成功 --------------------------------
# 不是每個專案都已經建過 PKB；.mra 缺席是合法狀態，不該被當成錯誤擋下來。
# 暫時把主要 fixture 的 .mra 搬開，驗完再搬回來，不要弄丟後面其他斷言在用
# 的那份 .mra。
mv "$R/.mra" "$TMP/mra-backup"
write_gh_stub "$BASE_SHA" 0
write_mra_stub "$STUB_REVIEW_JSON" 0
out_nomra="$("$ADAPTER" review acme/rails-app-1 --pr 101 --strategy personas --json 2>"$TMP/nomra.err")"
rc_nomra=$?
mv "$TMP/mra-backup" "$R/.mra"
eq "來源沒有 .mra 時退出碼仍是 0(缺席不算錯)" "0" "$rc_nomra"
eq "來源沒有 .mra 時仍印出 stub JSON 原樣" "$STUB_REVIEW_JSON" "$out_nomra"
has "來源沒有 .mra 時 worktree 裡也確實沒有 .mra(沒有憑空生出東西)" \
  "$(cat "$WT_LOG")" "mra_dir=MISSING"
lacks "來源沒有 .mra 時不該印出 PKB_COPY_FAILED" "$(cat "$TMP/nomra.err")" "PKB_COPY_FAILED"

# --- 清理失敗只印警告，不改變退出碼 -----------------------------------------
# 讓 mra stub 在還活著的時候(worktree 還存在)把 worktree 的父目錄改成不可寫：
# 刪掉一個目錄項目要的是父目錄的寫入權限，所以 review 本身照樣成功(stub 正常
# 吐出合法 JSON、exit 0)，而事後 adapter 的清理(git worktree remove --force
# 與 rm -rf 兩條路徑)都會失敗，藉此驗證「清理失敗不會讓一次成功的 review 變成
# 回報失敗」。測完要自己把權限改回來，不然這支測試檔案自己最後的 $TMP 清理也
# 會失敗。
#
# 這裡原本用 chflags uchg(macOS 的 user-immutable flag)，Linux 沒有這個指令，
# CI 上 stub 直接 command not found，兩條斷言連同後面「來源 repo 未提交變更的
# 筆數」一起紅。權限是 POSIX 語意，兩個平台一致。
#
# root 不受權限限制，這一段對 root 沒有意義。以 root 跑時明說跳過，不要讓它
# 看起來像通過——恆真的斷言比沒有斷言更糟。
if [[ "$(id -u)" == "0" ]]; then
  echo "SKIP: 清理失敗那三條以 root 執行時無法構造(權限對 root 無效)"
else
  cat > "$FAKE/bin/mra.sh" <<EOF
#!/usr/bin/env bash
chmod a-w .
printf '%s' '$STUB_REVIEW_JSON'
EOF
  chmod +x "$FAKE/bin/mra.sh"
  write_gh_stub "$BASE_SHA" 0
  out_cleanupfail="$("$ADAPTER" review acme/rails-app-1 --pr 101 --strategy personas --json 2>"$TMP/cleanupfail.err")"
  rc_cleanupfail=$?
  eq "清理失敗不影響退出碼，review 本身成功仍是 0" "0" "$rc_cleanupfail"
  eq "清理失敗時仍印出 stub JSON 原樣(不是把清理失敗混進 review 結果)" \
    "$STUB_REVIEW_JSON" "$out_cleanupfail"
  has "清理失敗有印出 WORKTREE_CLEANUP_FAILED 警告" \
    "$(cat "$TMP/cleanupfail.err")" "WORKTREE_CLEANUP_FAILED"
  # 驗完把權限改回來、清掉殘留，不要留給檔案結尾的 $TMP 清理去處理。
  chmod u+w "$WT_ROOT"
  rm -rf "$WT_ROOT/rails-app-1"
  git -C "$R" worktree prune >/dev/null 2>&1
fi

# --- 從頭到尾，來源 repo 的 HEAD 與未提交變更都沒被動過 ---------------------
# 這支測試檔案跑到這裡已經呼叫過 adapter 十幾次，每一次都會建、清一次
# worktree；這條斷言放在最後，等於驗證「所有這些呼叫加總起來」都沒有動到
# 來源 repo 一絲一毫，不是只驗其中一次。
eq "來源 repo 的 HEAD 全程沒有被動過" "$ORIG_HEAD_SHA" "$(git -C "$R" rev-parse HEAD)"
eq "來源 repo 未提交變更的筆數全程沒有被動過" "$ORIG_STATUS_LINES" \
  "$(git -C "$R" status --porcelain | wc -l | tr -d ' ')"

# --- 平行跑兩份時不能互相覆寫 ---------------------------------------------
# 原本 worktree 根目錄與衍生設定都是固定路徑：兩輪回測同時跑同一個 repo 時，
# 後啟動的那個在「自救」階段會把前一個正在 review 的 worktree 直接
# worktree remove --force 掉，受害者在一個已被刪的目錄裡跑完、退出 0、產出空的
# comments 陣列 —— 那份輸出通過 run-backtest.sh 的三道關卡，被當成「跑完了、
# 零發現」計入彙總。衍生設定同理：實測 personas 那一輪跑在 providerMode=codex
# 底下，而 run-conditions.json 記的是 claude。
#
# 這裡不真的跑兩個 review（太慢），只驗「路徑本身含 PID」這個隔離機制。
test_paths_are_process_isolated() {
  local out_a out_b
  # 用 --print-paths 之類的旗標不存在，改用最輕的方式：直接讀腳本算出來的路徑。
  # 兩個子行程各自 source 到路徑計算那一段為止，印出它們算出的路徑。
  out_a="$(bash -c '
    BT_WS="${MRA_BACKTEST_WT_ROOT:-${TMPDIR:-/tmp}/mra-backtest-ws-$$}"
    printf "%s\n" "$BT_WS"
    printf "%s\n" "${TMPDIR:-/tmp}/mra-backtest-config-$$.json"
  ')"
  out_b="$(bash -c '
    BT_WS="${MRA_BACKTEST_WT_ROOT:-${TMPDIR:-/tmp}/mra-backtest-ws-$$}"
    printf "%s\n" "$BT_WS"
    printf "%s\n" "${TMPDIR:-/tmp}/mra-backtest-config-$$.json"
  ')"
  if [ "$out_a" != "$out_b" ]; then
    ok "兩個行程算出的 worktree 根目錄與衍生設定路徑不同"
  else
    fail "兩個行程算出相同的路徑，平行跑會互相覆寫：$out_a"
  fi
}

# 腳本裡真的用了帶 PID 的路徑，不是只有測試自己在算。
test_script_uses_pid_in_paths() {
  local src; src="$(cat "$REAL_ADAPTER")"
  has "worktree 根目錄帶 PID" "$src" 'mra-backtest-ws-$$'
  has "衍生設定帶 PID" "$src" 'mra-backtest-config-$$.json'
}

# 呼叫端指定目錄時用固定檔名（測試需要可預測的路徑），並由呼叫端負責隔離。
test_config_dir_override_uses_stable_name() {
  local src; src="$(cat "$REAL_ADAPTER")"
  has "指定 MRA_BACKTEST_CONFIG_DIR 時用固定檔名" "$src" 'MRA_BACKTEST_CONFIG_DIR/mra-backtest-config.json'
}

# gh 查 PR 失敗時要保留它的 stderr。一輪回測跑幾小時，.err 檔裡只有「退出碼 1」
# 的話，額度用盡、token 失權、repo 不存在這三件事完全分不出來，而它們的處置
# 分別是「等」「重新認證」「改基準集」。
test_pr_lookup_failure_keeps_gh_diagnostics() {
  local ghbin="$TMP/bin-gh-fail"
  mkdir -p "$ghbin"
  cat > "$ghbin/gh" <<'STUB'
#!/usr/bin/env bash
echo "gh: API rate limit exceeded for user ID 12345. Resets at 2026-08-23T10:00:00Z" >&2
exit 1
STUB
  chmod +x "$ghbin/gh"
  local out
  # 借用上面 pull-ref 測試已經備好的真 git 專案，這樣才會走到查 PR 那一步
  # （專案不存在的話會先撞 PROJECT_NOT_FOUND）。
  out="$(PATH="$ghbin:$PATH" MRA_BACKTEST_CONFIG_DIR="$TMP/derived" \
    MRA_BACKTEST_WORKSPACE="$PULLREF_DIR/ws" \
    bash "$ADAPTER" review acme/rails-app-1 --pr 9001 2>&1)"
  has "印出 PR_LOOKUP_FAILED" "$out" "PR_LOOKUP_FAILED"
  has "保留 gh 的實際訊息（分得出是額度問題）" "$out" "rate limit exceeded"
  has "保留可行動的細節（何時重置）" "$out" "Resets at"
}

test_paths_are_process_isolated
test_script_uses_pid_in_paths
test_config_dir_override_uses_stable_name
test_pr_lookup_failure_keeps_gh_diagnostics

echo "---"; echo "Passed: $pass"; echo "Failed: $errors"
exit $((errors > 0 ? 1 : 0))
