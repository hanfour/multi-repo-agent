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

R="$WS/erp"
git -C "$R" init -q -b main 2>/dev/null || { mkdir -p "$R"; git -C "$R" init -q -b main; }
git -C "$R" config user.email t@t.t; git -C "$R" config user.name t
printf 'one\n' > "$R/f.txt"; git -C "$R" add f.txt; git -C "$R" commit -q -m base
BASE_SHA="$(git -C "$R" rev-parse HEAD)"
printf 'two\n' >> "$R/f.txt"; git -C "$R" add f.txt; git -C "$R" commit -q -m head
HEAD_SHA="$(git -C "$R" rev-parse HEAD)"

# 模擬使用者手邊正在做的事(真實情境：~/workspace/erp checkout 在
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
{
  printf 'cwd=%s\n' "\$(pwd)"
  printf 'worktree_head=%s\n' "\$(git -C erp rev-parse HEAD 2>&1)"
  printf 'collab_files=%s\n' "\$(ls .collab 2>&1 | tr '\n' ',')"
  if [[ -L erp/.mra ]]; then
    printf 'mra_dir=SYMLINK\n'
  elif [[ -d erp/.mra ]]; then
    printf 'mra_dir=REALDIR\n'
  else
    printf 'mra_dir=MISSING\n'
  fi
  printf 'mra_pkb_files=%s\n' "\$(ls erp/.mra/pkb 2>&1 | tr '\n' ',')"
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

# --- owner/repo 正確拆成專案名：mra.sh 收到的是 erp，不是 acme/rails-app-1 -------
argv="$(cat "$ARGV_LOG")"
has "owner/repo 拆成專案名 erp 傳給 mra" "$argv" "review erp "
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

# --- codex model 覆蓋 -------------------------------------------------------
# config.json 的 review.models.codex 是共用設定（在版控內），回測不改它，改用
# mra review 的 --model 旗標。兩種模式都要帶：providerMode 預設 codex，
# personas 模式一樣走到同一個 provider。
cfg_dir="$TMP/derived"; mkdir -p "$cfg_dir"
out_cfg="$(MRA_BACKTEST_REVIEW_MODE=standard MRA_BACKTEST_CONFIG_DIR="$cfg_dir" \
  "$ADAPTER" review acme/rails-app-1 --pr 101 --strategy personas --json 2>"$TMP/cfg.err")"
rc_cfg=$?
eq "產生衍生設定時退出碼 0" "0" "$rc_cfg"
derived="$cfg_dir/mra-backtest-config.json"
if [[ -s "$derived" ]]; then ok "衍生設定檔有寫出來"; else fail "衍生設定檔沒寫出來：$derived"; fi
eq "衍生設定的 codex model 是 gpt-5.5" "gpt-5.5" "$(jq -r '.review.models.codex' "$derived" 2>/dev/null)"
eq "衍生設定的 reasoning effort 是 xhigh" "xhigh" "$(jq -r '.review.codexReasoningEffort' "$derived" 2>/dev/null)"
eq "來源 config.json 沒有被改動" "gpt-5.6-luna" \
  "$(jq -r '.review.models.codex' "$FAKE/config.json" 2>/dev/null)"
# 只檢查衍生檔的內容不夠：export 掉了的話 mra 仍讀共用設定，機制整個失效而
# 測試照樣綠。這一條斷言 mra 真的收到指向衍生檔的 MRA_CONFIG。
has "mra 收到指向衍生設定的 MRA_CONFIG" "$(cat "$ENV_LOG")" "MRA_CONFIG=$derived"

# 呼叫端自己指定 MRA_CONFIG 時，adapter 不覆蓋。
rm -f "$ENV_LOG"
caller_cfg="$TMP/caller-config.json"
cp "$FAKE/config.json" "$caller_cfg"
out_cfg_caller="$(MRA_BACKTEST_REVIEW_MODE=standard MRA_CONFIG="$caller_cfg" \
  "$ADAPTER" review acme/rails-app-1 --pr 101 --strategy personas --json 2>"$TMP/cfg-caller.err")"
eq "呼叫端指定 MRA_CONFIG 時退出碼 0" "0" "$?"
has "呼叫端指定的 MRA_CONFIG 不被覆蓋" "$(cat "$ENV_LOG")" "MRA_CONFIG=$caller_cfg"

out_cfg2="$(MRA_BACKTEST_REVIEW_MODE=standard MRA_BACKTEST_CONFIG_DIR="$cfg_dir" \
  MRA_BACKTEST_CODEX_MODEL=gpt-4.9 MRA_BACKTEST_CODEX_EFFORT=high \
  "$ADAPTER" review acme/rails-app-1 --pr 101 --strategy personas --json 2>"$TMP/cfg2.err")"
eq "MRA_BACKTEST_CODEX_MODEL 會覆蓋預設值" "gpt-4.9" \
  "$(jq -r '.review.models.codex' "$derived" 2>/dev/null)"
eq "MRA_BACKTEST_CODEX_EFFORT 會覆蓋預設值" "high" \
  "$(jq -r '.review.codexReasoningEffort' "$derived" 2>/dev/null)"

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
WT_TARGET="$WT_ROOT/erp"
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
# 讓 mra stub 在還活著的時候(worktree 還存在)把 worktree 目錄整個標成
# uchg(macOS 的 user-immutable flag)：這樣 review 本身照樣成功(stub 正常吐
# 出合法 JSON、exit 0)，但事後 adapter 的清理(git worktree remove --force
# 與 rm -rf 兩條路徑)都會因為這個 flag 而失敗，藉此驗證「清理失敗不會讓一次
# 成功的 review 變成回報失敗」。測完要自己解除 flag，不然這支測試檔案自己
# 最後的 $TMP 清理也會失敗。
cat > "$FAKE/bin/mra.sh" <<EOF
#!/usr/bin/env bash
chflags uchg erp
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
# 驗完手動解除 flag、清掉殘留，不要留給檔案結尾的 $TMP 清理去處理。
chflags -R nouchg "$WT_ROOT/erp" 2>/dev/null
rm -rf "$WT_ROOT/erp"
git -C "$R" worktree prune >/dev/null 2>&1

# --- 從頭到尾，來源 repo 的 HEAD 與未提交變更都沒被動過 ---------------------
# 這支測試檔案跑到這裡已經呼叫過 adapter 十幾次，每一次都會建、清一次
# worktree；這條斷言放在最後，等於驗證「所有這些呼叫加總起來」都沒有動到
# 來源 repo 一絲一毫，不是只驗其中一次。
eq "來源 repo 的 HEAD 全程沒有被動過" "$ORIG_HEAD_SHA" "$(git -C "$R" rev-parse HEAD)"
eq "來源 repo 未提交變更的筆數全程沒有被動過" "$ORIG_STATUS_LINES" \
  "$(git -C "$R" status --porcelain | wc -l | tr -d ' ')"

echo "---"; echo "Passed: $pass"; echo "Failed: $errors"
exit $((errors > 0 ? 1 : 0))
