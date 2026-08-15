# 階段一：語料取材與篩選 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 抓取外部開源專案資深 reviewer 的 PR review comment，篩掉 bot 與 nit，存成後續萃取規則用的語料庫。

**Architecture:** 三個 bash lib 檔加一個 CLI 腳本。抓取以「每頁一個檔案」為單位，重跑跳過已存在的檔，所以 rate limit 或網路中斷後可以續抓。篩選五步各自是讀 stdin 寫 stdout 的獨立函式，可單獨測試也可串成管線。

**Tech Stack:** bash、`gh` CLI、jq 1.8。不引入新的執行期依賴。

**Spec:** `docs/superpowers/specs/2026-08-14-team-code-review-ruleset-design.md`

## Global Constraints

- 語料存 `${MRA_CORPUS_DIR:-$HOME/.cache/mra-review-corpus}`，不進 git。
- 檔案結構 `<cache>/<owner>__<name>/<4位數頁碼>.json`，例如 `rails__rails/0001.json`。
- 層的值域固定五個：`common`、`nestjs`、`rails`、`react`、`vue`。
- 打到 rate limit 要停下來印出還剩幾頁未抓，不得靜默截斷。
- 所有新檔案要通過 `make lint`（shellcheck `-S warning`）。
- 測試檔放 `tests/test_*.sh`，由 `bash test.sh` 自動發現，結尾用既有慣例：`echo "---"; echo "Passed: $pass"; echo "Failed: $errors"; exit $((errors > 0 ? 1 : 0))`。
- 每新增一個 `lib/*.sh`，都要把它加進 `bin/mra.sh` 的 `MRA_LIBS` 清單。`tests/test_lib_loader.sh` 會驗這件事（issue #39：`MRA_LIBS` 是明確排序清單而不是 glob，忘記註冊的 lib 會在執行期靜默缺席）。加在 review 那一區之後即可，這些檔案都是純函式定義，載入順序無關。
- 不要用 `awk -v var="$值"` 傳任意字串。awk 的 `-v` 會先處理反斜線跳脫，`rails\/rails`（12 位元組）會被收合成 `rails/rails`（11 位元組）而誤配。改用 `var="$值" awk '... ENVIRON["var"] ...'`。含換行的值還會讓 awk 直接 crash。

---

### Task 1: 目標 repo 清單與層對應

**Files:**
- Create: `lib/corpus-targets.sh`
- Test: `tests/test_corpus_targets.sh`

**Interfaces:**
- Consumes: 無
- Produces:
  - `corpus_layers()` → stdout 一行一個層名，共五行
  - `corpus_targets()` → stdout 一行一筆 `<owner/name>\t<layer>`
  - `corpus_layer_of <repo>` → stdout 該 repo 的層名；repo 不在清單中時退出碼非 0 且不輸出

- [ ] **Step 1: 寫失敗的測試**

建立 `tests/test_corpus_targets.sh`：

```bash
#!/usr/bin/env bash
# 目標 repo 清單的結構驗證 (lib/corpus-targets.sh)。
set -uo pipefail
MRA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$MRA_DIR/lib/corpus-targets.sh"

errors=0; pass=0
ok()   { echo "PASS: $1"; pass=$((pass+1)); }
fail() { echo "FAIL: $1"; errors=$((errors+1)); }
eq()   { if [[ "$2" == "$3" ]]; then ok "$1"; else fail "$1 — expected [$2] got [$3]"; fi; }

eq "五個層" "5" "$(corpus_layers | wc -l | tr -d ' ')"

# 每行剛好兩欄
bad_cols=$(corpus_targets | awk -F'\t' 'NF != 2' | wc -l | tr -d ' ')
eq "每行兩欄" "0" "$bad_cols"

# 每個 layer 都在值域內
valid=$(corpus_layers | tr '\n' '|' | sed 's/|$//')
bad_layer=$(corpus_targets | awk -F'\t' -v v="^($valid)$" '$2 !~ v' | wc -l | tr -d ' ')
eq "layer 都在值域內" "0" "$bad_layer"

# repo 不重複
n_all=$(corpus_targets | wc -l | tr -d ' ')
n_uniq=$(corpus_targets | cut -f1 | sort -u | wc -l | tr -d ' ')
eq "repo 不重複" "$n_all" "$n_uniq"

# spec 點名的 repo 都在，而且各自在對的 layer。
# 只 grep repo 欄不夠：把 microsoft/TypeScript 標成 vue、vuejs/vue 標成 common 的 mutant
# 一樣會全過，那個測試等於沒測 layer。所以每一筆都釘死成字面值。
check_pair() {
  local repo="$1" want="$2" got
  got="$(corpus_targets | awk -F'\t' -v r="$repo" '$1 == r { print $2 }')"
  eq "$repo → $want" "$want" "$got"
}
check_pair microsoft/TypeScript common
check_pair nestjs/nest          nestjs
check_pair nestjs/typeorm       nestjs
check_pair nestjs/swagger       nestjs
check_pair prisma/prisma        nestjs
check_pair rails/rails          rails
check_pair facebook/react       react
check_pair TanStack/query       react
check_pair vuejs/vue            vue
check_pair vuejs/core           vue

# 清單長度也釘住，避免有人多加一筆而沒人發現
eq "共 10 個 repo" "10" "$(corpus_targets | wc -l | tr -d ' ')"

# NestJS 語料補強：nestjs 層至少四個 repo
n_nest=$(corpus_targets | awk -F'\t' '$2=="nestjs"' | wc -l | tr -d ' ')
if [[ "$n_nest" -ge 4 ]]; then ok "nestjs 層有 $n_nest 個 repo"; else fail "nestjs 層只有 $n_nest 個，spec 要求補強"; fi

eq "查得到 rails/rails" "rails" "$(corpus_layer_of rails/rails)"
eq "查得到 facebook/react" "react" "$(corpus_layer_of facebook/react)"

if corpus_layer_of no/such-repo >/dev/null 2>&1; then
  fail "未知 repo 應退出非 0"
else
  ok "未知 repo 退出非 0"
fi
eq "未知 repo 不輸出" "" "$(corpus_layer_of no/such-repo 2>/dev/null)"

echo "---"; echo "Passed: $pass"; echo "Failed: $errors"
exit $((errors > 0 ? 1 : 0))
```

- [ ] **Step 2: 跑測試確認失敗**

Run: `bash tests/test_corpus_targets.sh`
Expected: FAIL，訊息是 `lib/corpus-targets.sh: No such file or directory`

- [ ] **Step 3: 寫最小實作**

建立 `lib/corpus-targets.sh`：

```bash
#!/usr/bin/env bash
# 外部語料的目標 repo 清單與所屬層。
#
# nestjs 層放了四個生態 repo：nestjs/nest 本身只有約 2,200 則 review comment，
# 但 NestJS 是 Acme PR 量最大的一層（約 720），單靠核心 repo 的語料寫不出
# 有判準的規則。

corpus_layers() {
  printf '%s\n' common nestjs rails react vue
}

corpus_targets() {
  cat <<'EOF'
microsoft/TypeScript	common
nestjs/nest	nestjs
nestjs/typeorm	nestjs
nestjs/swagger	nestjs
prisma/prisma	nestjs
rails/rails	rails
facebook/react	react
TanStack/query	react
vuejs/vue	vue
vuejs/core	vue
EOF
}

# repo 名稱透過 ENVIRON 傳給 awk，不用 -v。awk 的 -v 會先處理反斜線跳脫：
# `rails\/rails` 會被收合成 `rails/rails` 而誤配成功，含換行的值還會讓 awk crash。
corpus_layer_of() {
  local repo="$1"
  corpus_targets \
    | CORPUS_REPO="$repo" awk -F'\t' '$1 == ENVIRON["CORPUS_REPO"] { print $2; found = 1 } END { exit !found }'
}
```

- [ ] **Step 4: 跑測試確認通過**

Run: `bash tests/test_corpus_targets.sh`
Expected: PASS，`Failed: 0`

- [ ] **Step 5: lint**

Run: `shellcheck -S warning lib/corpus-targets.sh tests/test_corpus_targets.sh`
Expected: 無輸出

- [ ] **Step 6: Commit**

```bash
git add lib/corpus-targets.sh tests/test_corpus_targets.sh
git commit -m "feat(corpus): 目標 repo 清單與層對應"
```

---

### Task 2: 分頁抓取與續抓

**Files:**
- Create: `lib/corpus-fetch.sh`
- Test: `tests/test_corpus_fetch.sh`

**Interfaces:**
- Consumes: 無（不依賴 Task 1）
- Produces:
  - `corpus_cache_dir()` → 語料根目錄字串
  - `corpus_repo_dir <repo>` → 該 repo 的目錄路徑
  - `corpus_page_file <repo> <page>` → 該頁的檔案路徑，頁碼補到四位數
  - `corpus_last_page <repo>` → 末頁頁數；無 Link header 時回 `1`
  - `corpus_fetch_page <repo> <page>` → 退出碼 `0` 已抓、`2` 已存在跳過、`1` 失敗
  - `corpus_rate_remaining()` → 剩餘 core rate limit 數字
  - `corpus_fetch_repo <repo> [min_rate]` → 退出碼 `0` 完成、`3` 因 rate limit 停止、`1` 有頁面失敗；stdout 一行 TSV 摘要

測試用 PATH shim 假造 `gh`，不打真實網路。

- [ ] **Step 1: 寫失敗的測試**

建立 `tests/test_corpus_fetch.sh`：

```bash
#!/usr/bin/env bash
# 分頁抓取與續抓 (lib/corpus-fetch.sh)。用 PATH shim 假造 gh，不打真實網路。
set -uo pipefail
MRA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export MRA_CORPUS_DIR="$TMP/cache"
# TMPDIR 指到本測試專屬的目錄。下面驗「mv 失敗不洩漏暫存檔」是用數 tmp.* 檔案做的，
# 指向共用的 TMPDIR 會數到其他行程的檔案（實測機器上有 321 個），變成間歇性紅燈。
# 這個套件會 gate 後面每一個 task，間歇性紅燈的代價遠高於這兩行。
export TMPDIR="$TMP/tmphome"
mkdir -p "$TMPDIR"

# --- 假造的 gh：依 GH_FAKE_MODE 改變行為，呼叫次數記在 GH_CALL_LOG
mkdir -p "$TMP/bin"
cat > "$TMP/bin/gh" <<'SHIM'
#!/usr/bin/env bash
echo "$*" >> "$GH_CALL_LOG"
case "$*" in
  *rate_limit*)
    # ratefail 模擬認證失敗或網路不通：gh 退出非 0 且不輸出
    if [[ "${GH_FAKE_MODE:-ok}" == "ratefail" ]]; then exit 1; fi
    printf '%s' "${GH_FAKE_RATE:-5000}"; exit 0 ;;
  *--include*)
    if [[ "${GH_FAKE_MODE:-ok}" == "nolink" ]]; then printf 'HTTP/2 200\n\n'; exit 0; fi
    printf 'HTTP/2 200\nLink: <https://api.github.com/x?page=2>; rel="next", <https://api.github.com/x?page=%s>; rel="last"\n\n' "${GH_FAKE_LAST:-3}"
    exit 0 ;;
  *pulls/comments*)
    if [[ "${GH_FAKE_MODE:-ok}" == "fail" ]]; then exit 1; fi
    if [[ "${GH_FAKE_MODE:-ok}" == "garbage" ]]; then printf 'not json'; exit 0; fi
    printf '[{"id":1,"body":"x"}]'; exit 0 ;;
esac
exit 1
SHIM
chmod +x "$TMP/bin/gh"
export PATH="$TMP/bin:$PATH"
export GH_CALL_LOG="$TMP/calls.log"; : > "$GH_CALL_LOG"

source "$MRA_DIR/lib/corpus-fetch.sh"

errors=0; pass=0
ok()   { echo "PASS: $1"; pass=$((pass+1)); }
fail() { echo "FAIL: $1"; errors=$((errors+1)); }
eq()   { if [[ "$2" == "$3" ]]; then ok "$1"; else fail "$1 — expected [$2] got [$3]"; fi; }

eq "cache dir 可覆寫" "$TMP/cache" "$(corpus_cache_dir)"
eq "repo dir 斜線換成雙底線" "$TMP/cache/rails__rails" "$(corpus_repo_dir rails/rails)"
eq "頁碼補四位數" "$TMP/cache/rails__rails/0007.json" "$(corpus_page_file rails/rails 7)"

eq "末頁取自 Link header" "3" "$(corpus_last_page rails/rails)"
GH_FAKE_LAST=598 eq "末頁 598" "598" "$(GH_FAKE_LAST=598 corpus_last_page rails/rails)"
eq "無 Link header 視為單頁" "1" "$(GH_FAKE_MODE=nolink corpus_last_page rails/rails)"

# 第一次抓：退出碼 0，檔案寫出
corpus_fetch_page rails/rails 1; eq "首抓退出 0" "0" "$?"
if [[ -s "$TMP/cache/rails__rails/0001.json" ]]; then ok "檔案已寫出"; else fail "檔案沒寫出"; fi

# 第二次抓同一頁：退出碼 2，且沒有新的 API 呼叫
before=$(grep -c 'pulls/comments' "$GH_CALL_LOG")
corpus_fetch_page rails/rails 1; eq "重抓退出 2（跳過）" "2" "$?"
after=$(grep -c 'pulls/comments' "$GH_CALL_LOG")
eq "跳過時不呼叫 API" "$before" "$after"

# API 失敗：退出碼 1，不留半截檔案
GH_FAKE_MODE=fail corpus_fetch_page rails/rails 2; eq "API 失敗退出 1" "1" "$?"
if [[ -e "$TMP/cache/rails__rails/0002.json" ]]; then fail "失敗時留下檔案"; else ok "失敗時不留檔"; fi

# 回傳不是 JSON 陣列：同樣視為失敗，不留檔
GH_FAKE_MODE=garbage corpus_fetch_page rails/rails 3; eq "非 JSON 退出 1" "1" "$?"
if [[ -e "$TMP/cache/rails__rails/0003.json" ]]; then fail "非 JSON 留下檔案"; else ok "非 JSON 不留檔"; fi

eq "rate remaining" "5000" "$(corpus_rate_remaining)"

# rate limit 不足時停止，並印出還剩幾頁
out="$(GH_FAKE_RATE=10 corpus_fetch_repo vuejs/vue 100)"; rc=$?
eq "rate 不足退出 3" "3" "$rc"
case "$out" in RATE_LIMIT_STOP*) ok "印出 RATE_LIMIT_STOP" ;; *) fail "缺 RATE_LIMIT_STOP：$out" ;; esac
case "$out" in *"	1	3"*) ok "印出停在第 1 頁/共 3 頁" ;; *) fail "缺頁數資訊：$out" ;; esac

# 正常跑完三頁
out="$(corpus_fetch_repo vuejs/vue 100)"; rc=$?
eq "正常跑完退出 0" "0" "$rc"
case "$out" in DONE*fetched=3*) ok "抓了三頁" ;; *) fail "頁數不對：$out" ;; esac

# 有頁面失敗時退出 1。沒有這條的話，把 `[[ "$failed" -eq 0 ]]` 改成無條件
# `return 0` 仍然會全綠：這是三個退出碼裡唯一沒被涵蓋的一個。
out="$(GH_FAKE_MODE=fail corpus_fetch_repo TanStack/query 100)"; rc=$?
eq "有頁面失敗退出 1" "1" "$rc"
case "$out" in DONE*failed=3*) ok "回報 failed=3" ;; *) fail "失敗數不對：$out" ;; esac

# 額度查不到（不是額度用盡）要印 RATE_CHECK_FAILED，不能印成 RATE_LIMIT_STOP，
# 否則操作者會以為要等一小時，實際上是認證或網路壞了。
out="$(GH_FAKE_MODE=ratefail corpus_fetch_repo prisma/prisma 100)"; rc=$?
eq "額度查不到退出 3" "3" "$rc"
case "$out" in RATE_CHECK_FAILED*) ok "印出 RATE_CHECK_FAILED" ;; *) fail "應為 RATE_CHECK_FAILED：$out" ;; esac
if corpus_rate_remaining >/dev/null 2>&1; then ok "額度正常時 corpus_rate_remaining 回 0"; else fail "額度正常時不該失敗"; fi
eq "額度查不到時無輸出" "" "$(GH_FAKE_MODE=ratefail corpus_rate_remaining 2>/dev/null)"

# mv 失敗不得回報成功。目的地唯讀時，corpus_fetch_page 要回 1 且不留暫存檔。
ro_dir="$(corpus_repo_dir microsoft/TypeScript)"
mkdir -p "$ro_dir"; chmod 555 "$ro_dir"
# 數的是本測試專屬 TMPDIR 裡的 corpus.* 暫存檔，所以是精確計數：
# 起點必為 0，洩漏一個就是 1。數共用 TMPDIR 的 tmp.* 會數到別的行程（實測機器上
# 有 321 個）而間歇性誤報，而 corpus_fetch_page 若用 bare mktemp，在 macOS 上又會
# 因為忽略 TMPDIR 而恆為 0/0，變成永遠不會失敗的空斷言。
tmp_before="$(find "$TMPDIR" -maxdepth 1 -name 'corpus.*' 2>/dev/null | wc -l | tr -d ' ')"
eq "起點沒有殘留暫存檔" "0" "$tmp_before"
corpus_fetch_page microsoft/TypeScript 1; rc=$?
chmod 755 "$ro_dir"
eq "mv 失敗退出 1" "1" "$rc"
if [[ -e "$ro_dir/0001.json" ]]; then fail "mv 失敗卻留下檔案"; else ok "mv 失敗不留檔"; fi
tmp_after="$(find "$TMPDIR" -maxdepth 1 -name 'corpus.*' 2>/dev/null | wc -l | tr -d ' ')"
eq "mv 失敗不洩漏暫存檔" "0" "$tmp_after"

echo "---"; echo "Passed: $pass"; echo "Failed: $errors"
exit $((errors > 0 ? 1 : 0))
```

- [ ] **Step 2: 跑測試確認失敗**

Run: `bash tests/test_corpus_fetch.sh`
Expected: FAIL，訊息是 `lib/corpus-fetch.sh: No such file or directory`

- [ ] **Step 3: 寫最小實作**

建立 `lib/corpus-fetch.sh`：

```bash
#!/usr/bin/env bash
# GitHub PR review comment 的分頁抓取。
#
# 每頁存成獨立檔案，重跑時跳過已存在且合法的檔，所以 rate limit 或網路中斷後
# 可以直接重跑續抓。打到 rate limit 時停下來印出還剩幾頁，不靜默截斷：2026-06-23
# 的 false-green 就是靜默截斷被當成「沒問題」造成的。

corpus_cache_dir() {
  printf '%s' "${MRA_CORPUS_DIR:-$HOME/.cache/mra-review-corpus}"
}

corpus_repo_dir() {
  local repo="$1"
  printf '%s/%s' "$(corpus_cache_dir)" "${repo//\//__}"
}

corpus_page_file() {
  local repo="$1" page="$2"
  printf '%s/%04d.json' "$(corpus_repo_dir "$repo")" "$page"
}

# 末頁頁數取自 Link header。沒有 Link header 代表結果只有一頁。
corpus_last_page() {
  local repo="$1" link last
  link=$(gh api "repos/$repo/pulls/comments?per_page=100&sort=created&direction=desc" \
           --include 2>/dev/null | grep -i '^link:') || true
  if [[ -z "${link:-}" ]]; then printf '1'; return 0; fi
  last=$(printf '%s' "$link" | grep -oE 'page=[0-9]+>; rel="last"' | grep -oE '[0-9]+' | head -1)
  printf '%s' "${last:-1}"
}

# 退出碼：0 已抓、2 已存在跳過、1 失敗。
corpus_fetch_page() {
  local repo="$1" page="$2" out tmp
  out="$(corpus_page_file "$repo" "$page")"
  if [[ -s "$out" ]] && jq -e 'type == "array"' "$out" >/dev/null 2>&1; then
    return 2
  fi
  mkdir -p "$(dirname "$out")"
  # 一定要給 mktemp 明確的 template。macOS/BSD 的 bare `mktemp` 走
  # _CS_DARWIN_USER_TEMP_DIR，完全忽略 TMPDIR（GNU 的會理），所以測試無法把暫存檔
  # 導到自己控制的目錄，「不洩漏暫存檔」那條斷言就會變成永遠 0/0 的空斷言。
  tmp="$(mktemp "${TMPDIR:-/tmp}/corpus.XXXXXX")" || return 1
  if ! gh api "repos/$repo/pulls/comments?per_page=100&page=$page&sort=created&direction=desc" \
         > "$tmp" 2>/dev/null; then
    rm -f "$tmp"; return 1
  fi
  if ! jq -e 'type == "array"' "$tmp" >/dev/null 2>&1; then
    rm -f "$tmp"; return 1
  fi
  # mv 的退出碼一定要檢查。TMPDIR 與快取目錄常在不同檔案系統上，mv 會退化成
  # copy + unlink，磁碟滿、配額、權限都可能讓它失敗。不檢查的話這裡會回報成功
  # 但快取是空的，而且暫存檔永遠留著。
  if ! mv "$tmp" "$out"; then
    rm -f "$tmp"; return 1
  fi
  return 0
}

# GET /rate_limit 本身不計入額度，所以可以放心每頁前查。
# 成功：印出剩餘數並回 0。失敗：不印任何東西並回 1，讓呼叫端能把「額度用盡」
# 和「查不到額度」分開報。舊版失敗時印 0，結果認證失敗會被印成 RATE_LIMIT_STOP，
# 操作者會白等一小時額度重置。
corpus_rate_remaining() {
  local n
  n="$(gh api rate_limit --jq '.resources.core.remaining' 2>/dev/null)" || return 1
  [[ "$n" =~ ^[0-9]+$ ]] || return 1
  printf '%s' "$n"
}

corpus_fetch_repo() {
  local repo="$1" min_rate="${2:-100}"
  local last page fetched=0 skipped=0 failed=0 remaining
  last="$(corpus_last_page "$repo")"
  for ((page = 1; page <= last; page++)); do
    # 額度查不到時 corpus_rate_remaining 回 0，行為上跟額度用盡一樣要停（fail closed），
    # 但訊息要分得出來：把認證失敗印成 RATE_LIMIT_STOP 會讓操作者白等一小時。
    if ! remaining="$(corpus_rate_remaining)"; then
      printf 'RATE_CHECK_FAILED\t%s\t%s\t%s\n' "$repo" "$page" "$last"
      return 3
    fi
    if [[ "$remaining" -lt "$min_rate" ]]; then
      printf 'RATE_LIMIT_STOP\t%s\t%s\t%s\n' "$repo" "$page" "$last"
      return 3
    fi
    corpus_fetch_page "$repo" "$page"
    case $? in
      0) fetched=$((fetched + 1)) ;;
      2) skipped=$((skipped + 1)) ;;
      *) failed=$((failed + 1)) ;;
    esac
  done
  printf 'DONE\t%s\tlast=%s\tfetched=%s\tskipped=%s\tfailed=%s\n' \
    "$repo" "$last" "$fetched" "$skipped" "$failed"
  [[ "$failed" -eq 0 ]]
}
```

- [ ] **Step 4: 跑測試確認通過**

Run: `bash tests/test_corpus_fetch.sh`
Expected: PASS，`Failed: 0`

- [ ] **Step 5: lint**

Run: `shellcheck -S warning lib/corpus-fetch.sh tests/test_corpus_fetch.sh`
Expected: 無輸出

- [ ] **Step 6: Commit**

```bash
git add lib/corpus-fetch.sh tests/test_corpus_fetch.sh
git commit -m "feat(corpus): 分頁抓取與續抓"
```

---

### Task 3: 五步篩選

**Files:**
- Create: `lib/corpus-filter.sh`
- Create: `tests/fixtures/corpus/sample-comments.json`
- Test: `tests/test_corpus_filter.sh`

**Interfaces:**
- Consumes: 無
- Produces（每個都讀 stdin 的 JSON 陣列、寫 stdout 的 JSON 陣列）：
  - `corpus_filter_bots`
  - `corpus_filter_senior`
  - `corpus_filter_quality`
  - `corpus_filter_prose`
  - `corpus_project <repo> <layer>` → 投影成語料欄位並保留 `diff_hunk`
  - `corpus_filter_all <repo> <layer>` → 串起五步；stdout 是最終陣列，stderr 是一行 TSV 留存數 `RETENTION\t<repo>\t<n0>\t<n1>\t<n2>\t<n3>\t<n4>`

- [ ] **Step 1: 建立測試 fixture**

建立 `tests/fixtures/corpus/sample-comments.json`。九筆各自命中一個篩選條件，讓每一步的留存數可以逐步斷言：

```json
[
  {"id":1,"user":{"login":"coderabbitai[bot]"},"author_association":"NONE",
   "body":"This is a long automated review comment that easily exceeds one hundred and fifty characters so that it would otherwise pass the quality gate on length alone.",
   "in_reply_to_id":null,"reactions":{"total_count":0},
   "path":"a.rb","diff_hunk":"@@ -1 +1 @@","html_url":"https://x/1","created_at":"2026-01-01T00:00:00Z"},

  {"id":2,"user":{"login":"dependabot"},"author_association":"NONE",
   "body":"This is a long automated dependency bump comment that easily exceeds one hundred and fifty characters so it would otherwise pass the quality gate on length.",
   "in_reply_to_id":null,"reactions":{"total_count":0},
   "path":"b.rb","diff_hunk":"@@ -1 +1 @@","html_url":"https://x/2","created_at":"2026-01-01T00:00:00Z"},

  {"id":3,"user":{"login":"outsider"},"author_association":"NONE",
   "body":"A long drive-by comment from someone with no association to the project, written long enough to exceed one hundred and fifty characters for this test case.",
   "in_reply_to_id":null,"reactions":{"total_count":0},
   "path":"c.rb","diff_hunk":"@@ -1 +1 @@","html_url":"https://x/3","created_at":"2026-01-01T00:00:00Z"},

  {"id":4,"user":{"login":"member1"},"author_association":"MEMBER",
   "body":"LGTM","in_reply_to_id":null,"reactions":{"total_count":0},
   "path":"d.rb","diff_hunk":"@@ -1 +1 @@","html_url":"https://x/4","created_at":"2026-01-01T00:00:00Z"},

  {"id":5,"user":{"login":"member1"},"author_association":"MEMBER",
   "body":"Treating the adapter API as public would prevent too many improvements. There is a handful of external adapters and we let the maintainers know when it changes.",
   "in_reply_to_id":null,"reactions":{"total_count":0},
   "path":"e.rb","diff_hunk":"@@ -10,3 +10,5 @@","html_url":"https://x/5","created_at":"2026-01-01T00:00:00Z"},

  {"id":6,"user":{"login":"member2"},"author_association":"COLLABORATOR",
   "body":"Right, that matches what I meant.","in_reply_to_id":999,"reactions":{"total_count":0},
   "path":"f.rb","diff_hunk":"@@ -1 +1 @@","html_url":"https://x/6","created_at":"2026-01-01T00:00:00Z"},

  {"id":7,"user":{"login":"member3"},"author_association":"OWNER",
   "body":"Good catch, this would have shipped a wrong total to the client.","in_reply_to_id":null,"reactions":{"total_count":2},
   "path":"g.rb","diff_hunk":"@@ -1 +1 @@","html_url":"https://x/7","created_at":"2026-01-01T00:00:00Z"},

  {"id":8,"user":{"login":"member1"},"author_association":"MEMBER",
   "body":"```suggestion\n  value.blank?\n```","in_reply_to_id":999,"reactions":{"total_count":0},
   "path":"h.rb","diff_hunk":"@@ -1 +1 @@","html_url":"https://x/8","created_at":"2026-01-01T00:00:00Z"},

  {"id":9,"user":{"login":"member1"},"author_association":"MEMBER",
   "body":"```suggestion\n  value.blank?\n```\n\nThe rest of the method uses blank? and present?, so this should match.",
   "in_reply_to_id":999,"reactions":{"total_count":0},
   "path":"i.rb","diff_hunk":"@@ -20,2 +20,4 @@","html_url":"https://x/9","created_at":"2026-01-01T00:00:00Z"}
]
```

各步預期留存：`9 → 7 → 6 → 5 → 4`。第 1 步濾掉 id 1、2；第 2 步濾掉 id 3；第 3 步濾掉 id 4（短、無回覆、無 reaction）；第 4 步濾掉 id 8（只有 suggestion 沒有說明）。

- [ ] **Step 2: 寫失敗的測試**

建立 `tests/test_corpus_filter.sh`：

```bash
#!/usr/bin/env bash
# 語料篩選五步 (lib/corpus-filter.sh)。
set -uo pipefail
MRA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$MRA_DIR/lib/corpus-filter.sh"
FX="$MRA_DIR/tests/fixtures/corpus/sample-comments.json"

errors=0; pass=0
ok()   { echo "PASS: $1"; pass=$((pass+1)); }
fail() { echo "FAIL: $1"; errors=$((errors+1)); }
eq()   { if [[ "$2" == "$3" ]]; then ok "$1"; else fail "$1 — expected [$2] got [$3]"; fi; }
n()    { jq 'length'; }
ids()  { jq -c '[.[].id]'; }

eq "fixture 九筆" "9" "$(n < "$FX")"

eq "1 去 bot 留 7"    "7" "$(corpus_filter_bots < "$FX" | n)"
eq "1 濾掉 id 1,2"    "[3,4,5,6,7,8,9]" "$(corpus_filter_bots < "$FX" | ids)"

eq "2 資深留 6"       "6" "$(corpus_filter_bots < "$FX" | corpus_filter_senior | n)"
eq "2 濾掉 id 3"      "[4,5,6,7,8,9]" "$(corpus_filter_bots < "$FX" | corpus_filter_senior | ids)"

eq "3 品質留 5"       "5" "$(corpus_filter_bots < "$FX" | corpus_filter_senior | corpus_filter_quality | n)"
eq "3 濾掉 id 4"      "[5,6,7,8,9]" "$(corpus_filter_bots < "$FX" | corpus_filter_senior | corpus_filter_quality | ids)"

eq "4 有說明留 4"     "4" "$(corpus_filter_bots < "$FX" | corpus_filter_senior | corpus_filter_quality | corpus_filter_prose | n)"
eq "4 濾掉 id 8"      "[5,6,7,9]" "$(corpus_filter_bots < "$FX" | corpus_filter_senior | corpus_filter_quality | corpus_filter_prose | ids)"

# 投影保留 diff_hunk 與出處 URL
proj="$(corpus_project rails/rails rails < "$FX")"
eq "投影保留 diff_hunk" "@@ -10,3 +10,5 @@" "$(printf '%s' "$proj" | jq -r '.[] | select(.id==5) | .diff_hunk')"
eq "投影帶 repo"        "rails/rails"       "$(printf '%s' "$proj" | jq -r '.[0].repo')"
eq "投影帶 layer"       "rails"             "$(printf '%s' "$proj" | jq -r '.[0].layer')"
eq "投影帶出處 URL"     "https://x/5"       "$(printf '%s' "$proj" | jq -r '.[] | select(.id==5) | .url')"
eq "投影帶 reviewer"    "member1"           "$(printf '%s' "$proj" | jq -r '.[] | select(.id==5) | .reviewer')"

# 串完整管線：stdout 是結果，stderr 是留存數
err="$(mktemp)"
outn="$(corpus_filter_all rails/rails rails < "$FX" 2>"$err" | n)"
eq "全管線留 4" "4" "$outn"
eq "留存數 TSV" "RETENTION	rails/rails	9	7	6	5	4" "$(cat "$err")"
rm -f "$err"

# 空輸入不炸
eq "空陣列進出都是 0" "0" "$(printf '[]' | corpus_filter_bots | corpus_filter_senior | corpus_filter_quality | corpus_filter_prose | n)"
eq "空陣列走全管線退出 0" "0" "$(printf '[]' | corpus_filter_all r l >/dev/null 2>&1; echo $?)"

# 壞掉的輸入必須失敗，不能靜默回 0。下游 build-corpus.sh 用這個退出碼判斷
# 該 repo 算不算失敗，回 0 的話壞資料會被當成「篩完 0 筆、一切正常」。
err2="$(mktemp)"
printf '{not valid json' | corpus_filter_all rails/rails rails >/dev/null 2>"$err2"; rc=$?
eq "壞輸入退出 1" "1" "$rc"
case "$(cat "$err2")" in FILTER_INPUT_INVALID*) ok "印出 FILTER_INPUT_INVALID" ;; *) fail "缺 FILTER_INPUT_INVALID：$(cat "$err2")" ;; esac
case "$(cat "$err2")" in *RETENTION*) fail "壞輸入不該印 RETENTION" ;; *) ok "壞輸入不印 RETENTION" ;; esac

# 非陣列的合法 JSON 也算壞輸入
printf '{"a":1}' | corpus_filter_all rails/rails rails >/dev/null 2>"$err2"; rc=$?
eq "JSON 物件也退出 1" "1" "$rc"

# 四個階段各自驗一次失敗會往上傳，而且錯誤訊息要指得出是哪一階段。
#
# 不要只測其中一個階段。守衛寫成 `local s1="$(...)" || {...}` 時 $? 恆為 0、守衛變成
# 死碼，只測 quality 的話另外三個階段被這樣寫也不會有人發現。實測過：只測 quality
# 時，把 bots 階段折成 local 一行寫法，整套仍然全綠。
for stage in bots senior quality prose; do
  orig_fn="$(declare -f "corpus_filter_$stage")"
  eval "corpus_filter_$stage() { return 5; }"
  printf '[]' | corpus_filter_all rails/rails rails >/dev/null 2>"$err2"; rc=$?
  eq "$stage 階段失敗退出 1" "1" "$rc"
  case "$(cat "$err2")" in
    *"FILTER_STAGE_FAILED"*"$stage"*) ok "$stage 階段名有印出" ;;
    *) fail "$stage 缺階段名：$(cat "$err2")" ;;
  esac
  eval "$orig_fn"
done
rm -f "$err2"

echo "---"; echo "Passed: $pass"; echo "Failed: $errors"
exit $((errors > 0 ? 1 : 0))
```

- [ ] **Step 3: 跑測試確認失敗**

Run: `bash tests/test_corpus_filter.sh`
Expected: FAIL，訊息是 `lib/corpus-filter.sh: No such file or directory`

- [ ] **Step 4: 寫最小實作**

建立 `lib/corpus-filter.sh`：

```bash
#!/usr/bin/env bash
# 語料篩選五步。每步是讀 stdin 寫 stdout 的獨立函式，可單獨測試也可串成管線。
#
# 第 1 步不是可選項：vuejs/core 近 300 則 review comment 有 186 則是 CodeRabbit，
# 不濾掉的話學到的是另一個 AI reviewer 的平均水準。

# shellcheck disable=SC2016
_CORPUS_JQ_DEFS='
def is_bot:
  (.user.login | ascii_downcase) as $u
  | ($u | test("\\[bot\\]$"))
    or (["coderabbitai","copilot","dependabot","github-actions","renovate"] | any(. == $u));
def senior:
  .author_association as $a
  | ($a == "MEMBER" or $a == "OWNER" or $a == "COLLABORATOR");
def quality:
  (.body | length) > 150
  or (.in_reply_to_id != null)
  or (.reactions.total_count > 0);
def has_prose:
  (.body | gsub("```suggestion(.|\\n)*?```"; "") | gsub("\\s"; "") | length) >= 20;
'
# 註：不要改成 gsub("```suggestion.*?```"; ""; "s")。jq 的 "s" flag 不會讓 `.`
# 匹配換行，suggestion 區塊會整段留著，只有 suggestion 沒有說明的意見就濾不掉。

corpus_filter_bots()    { jq "$_CORPUS_JQ_DEFS [ .[] | select(is_bot | not) ]"; }
corpus_filter_senior()  { jq "$_CORPUS_JQ_DEFS [ .[] | select(senior) ]"; }
corpus_filter_quality() { jq "$_CORPUS_JQ_DEFS [ .[] | select(quality) ]"; }
corpus_filter_prose()   { jq "$_CORPUS_JQ_DEFS [ .[] | select(has_prose) ]"; }

# diff_hunk 是整份語料最有價值的欄位：它讓每則意見自帶被批評的那段程式碼。
corpus_project() {
  local repo="$1" layer="$2"
  jq --arg repo "$repo" --arg layer "$layer" '[ .[] | {
    id,
    repo: $repo,
    layer: $layer,
    reviewer: .user.login,
    association: .author_association,
    path,
    diff_hunk,
    body,
    in_reply_to: .in_reply_to_id,
    reactions: .reactions.total_count,
    url: .html_url,
    created_at
  } ]'
}

# stdout：最終陣列。stderr：一行 TSV 留存數，讓呼叫端能記錄每一步濾掉多少。
# 任何一階段失敗就回 1，不得回 0。下游 scripts/build-corpus.sh 要靠這個退出碼決定
# 該 repo 算不算失敗；吃掉錯誤的話，輸入壞掉或 GitHub schema 改變會變成「篩完 0 筆、
# 一切正常」，正是這份設計要避免的 false-green。
#
# 兩個 bash 細節，不要「整理」掉：
#   1. `local s0 s1 …` 必須單獨一行宣告，指派另外寫。寫成 `local s1="$(...)"` 的話，
#      $? 拿到的是 local 自己的退出碼（永遠 0），命令替換的失敗會被吞掉。
#   2. jq 解析失敗的退出碼是 5，不是 1，所以用 `|| return 1` 判斷而不是比對數值。
corpus_filter_all() {
  local repo="$1" layer="$2"
  local s0 s1 s2 s3 s4
  s0="$(cat)"

  # 先驗輸入。壞掉的輸入要當場失敗，而不是讓四個 jq 各噴一次錯之後回 0。
  if ! printf '%s' "$s0" | jq -e 'type == "array"' >/dev/null 2>&1; then
    printf 'FILTER_INPUT_INVALID\t%s\n' "$repo" >&2
    return 1
  fi

  s1="$(printf '%s' "$s0" | corpus_filter_bots)" \
    || { printf 'FILTER_STAGE_FAILED\t%s\tbots\n' "$repo" >&2; return 1; }
  s2="$(printf '%s' "$s1" | corpus_filter_senior)" \
    || { printf 'FILTER_STAGE_FAILED\t%s\tsenior\n' "$repo" >&2; return 1; }
  s3="$(printf '%s' "$s2" | corpus_filter_quality)" \
    || { printf 'FILTER_STAGE_FAILED\t%s\tquality\n' "$repo" >&2; return 1; }
  s4="$(printf '%s' "$s3" | corpus_filter_prose)" \
    || { printf 'FILTER_STAGE_FAILED\t%s\tprose\n' "$repo" >&2; return 1; }
  printf 'RETENTION\t%s\t%s\t%s\t%s\t%s\t%s\n' "$repo" \
    "$(printf '%s' "$s0" | jq 'length')" \
    "$(printf '%s' "$s1" | jq 'length')" \
    "$(printf '%s' "$s2" | jq 'length')" \
    "$(printf '%s' "$s3" | jq 'length')" \
    "$(printf '%s' "$s4" | jq 'length')" >&2
  printf '%s' "$s4" | corpus_project "$repo" "$layer"
}
```

- [ ] **Step 5: 跑測試確認通過**

Run: `bash tests/test_corpus_filter.sh`
Expected: PASS，`Failed: 0`

- [ ] **Step 6: lint**

Run: `shellcheck -S warning lib/corpus-filter.sh tests/test_corpus_filter.sh`
Expected: 無輸出

- [ ] **Step 7: Commit**

```bash
git add lib/corpus-filter.sh tests/test_corpus_filter.sh tests/fixtures/corpus/sample-comments.json
git commit -m "feat(corpus): 五步篩選與投影"
```

---

### Task 4: CLI 進入點與留存率報告

**Files:**
- Create: `scripts/build-corpus.sh`
- Test: `tests/test_build_corpus.sh`

**Interfaces:**
- Consumes: Task 1 的 `corpus_targets`、`corpus_layer_of`；Task 2 的 `corpus_fetch_repo`、`corpus_repo_dir`；Task 3 的 `corpus_filter_all`
- Produces:
  - `scripts/build-corpus.sh [--repo <owner/name>] [--fetch-only] [--filter-only]`
  - 篩選後語料寫到 `<cache>/<owner>__<name>/filtered.json`
  - 留存率報告寫到 `<cache>/retention.tsv`，欄位 `repo n0 n1 n2 n3 n4`
  - 退出碼：`0` 全部完成、`3` 因 rate limit 中途停止（可重跑續抓）、`1` 有 repo 失敗

- [ ] **Step 1: 寫失敗的測試**

建立 `tests/test_build_corpus.sh`：

```bash
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
eq "留存數那行" "rails/rails	9	7	6	5	4" "$(grep '^rails/rails' "$r")"

# 重跑：不重複追加同一個 repo 的留存列
bash "$MRA_DIR/scripts/build-corpus.sh" --repo rails/rails >/dev/null 2>&1
eq "重跑後仍只有一列" "1" "$(grep -c '^rails/rails' "$r")"

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

echo "---"; echo "Passed: $pass"; echo "Failed: $errors"
exit $((errors > 0 ? 1 : 0))
```

- [ ] **Step 2: 跑測試確認失敗**

Run: `bash tests/test_build_corpus.sh`
Expected: FAIL，訊息是 `scripts/build-corpus.sh: No such file or directory`

- [ ] **Step 3: 寫最小實作**

建立 `scripts/build-corpus.sh`：

```bash
#!/usr/bin/env bash
# 語料取材 CLI：抓取目標 repo 的 PR review comment 並套用五步篩選。
#
# 可重複執行。已抓過的頁面會跳過，所以 rate limit 中斷後直接重跑即可續抓。
set -uo pipefail

MRA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$MRA_DIR/lib/corpus-targets.sh"
source "$MRA_DIR/lib/corpus-fetch.sh"
source "$MRA_DIR/lib/corpus-filter.sh"

ONLY_REPO=""; DO_FETCH=1; DO_FILTER=1
while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo)        ONLY_REPO="$2"; shift 2 ;;
    --fetch-only)  DO_FILTER=0; shift ;;
    --filter-only) DO_FETCH=0; shift ;;
    -h|--help)
      echo "用法: build-corpus.sh [--repo <owner/name>] [--fetch-only] [--filter-only]"
      exit 0 ;;
    *) echo "未知參數：$1" >&2; exit 1 ;;
  esac
done

RETENTION="$(corpus_cache_dir)/retention.tsv"
mkdir -p "$(corpus_cache_dir)"
[[ -f "$RETENTION" ]] || printf 'repo\tn0_raw\tn1_nobot\tn2_senior\tn3_quality\tn4_prose\n' > "$RETENTION"

if [[ -n "$ONLY_REPO" ]]; then
  if ! layer="$(corpus_layer_of "$ONLY_REPO")"; then
    echo "不在目標清單中的 repo：$ONLY_REPO" >&2
    exit 1
  fi
  targets="$(printf '%s\t%s\n' "$ONLY_REPO" "$layer")"
else
  targets="$(corpus_targets)"
fi

rc=0
while IFS=$'\t' read -r repo layer; do
  [[ -z "$repo" ]] && continue

  if [[ "$DO_FETCH" == 1 ]]; then
    if ! out="$(corpus_fetch_repo "$repo")"; then
      status=$?
      echo "$out" >&2
      if [[ "$status" == 3 ]]; then exit 3; fi
      rc=1
      continue
    fi
    echo "$out"
  fi

  if [[ "$DO_FILTER" == 1 ]]; then
    dir="$(corpus_repo_dir "$repo")"
    pages=("$dir"/[0-9]*.json)
    if [[ ! -e "${pages[0]}" ]]; then
      echo "沒有已抓取的頁面：$repo" >&2
      rc=1
      continue
    fi
    err="$(mktemp)"
    jq -s 'add' "${pages[@]}" \
      | corpus_filter_all "$repo" "$layer" 2>"$err" \
      > "$dir/filtered.json"
    # 重跑時先移除舊列，避免同一個 repo 累積多列
    grep -v "^$repo	" "$RETENTION" > "$RETENTION.tmp" || true
    mv "$RETENTION.tmp" "$RETENTION"
    sed 's/^RETENTION\t//' "$err" >> "$RETENTION"
    rm -f "$err"
  fi
done <<< "$targets"

exit "$rc"
```

- [ ] **Step 4: 跑測試確認通過**

Run: `bash tests/test_build_corpus.sh`
Expected: PASS，`Failed: 0`

- [ ] **Step 5: 跑全套測試確認沒弄壞既有的**

Run: `make test`
Expected: 既有 111 個測試加新增 4 個全數通過

- [ ] **Step 6: lint**

Run: `shellcheck -S warning scripts/build-corpus.sh tests/test_build_corpus.sh`
Expected: 無輸出

- [ ] **Step 7: Commit**

```bash
git add scripts/build-corpus.sh tests/test_build_corpus.sh
git commit -m "feat(corpus): 取材 CLI 與留存率報告"
```

---

### Task 5: 對真實 API 跑一次並記錄實際留存

這是階段一的驗收。前四個 task 都用假造的 `gh`，這一步確認對真實 API 也成立。

**Files:**
- Modify: 無程式碼變更；產出 `docs/superpowers/notes/2026-corpus-retention.md`

- [ ] **Step 1: 確認額度足夠**

Run: `gh api rate_limit --jq '.resources.core.remaining'`
Expected: 大於 2000。約 1,700 次呼叫才抓得完全部目標 repo。

- [ ] **Step 2: 先跑一個 repo 驗證管線**

```bash
bash scripts/build-corpus.sh --repo nestjs/nest
cat "${MRA_CORPUS_DIR:-$HOME/.cache/mra-review-corpus}/retention.tsv"
```

Expected: `nestjs/nest` 那列的 `n0_raw` 約 2,200。留存率（`n4_prose / n0_raw`）落在 30% 到 50% 之間。rails/rails 最新 100 則的實測是 41%，其他 repo 在這個範圍外的話要先看是不是篩選條件對該 repo 不適用，不要直接放大跑。

- [ ] **Step 3: 跑完全部目標 repo**

```bash
bash scripts/build-corpus.sh
```

打到 rate limit 會退出 3 並印出停在哪一頁，等額度重置後重跑同一行指令續抓。

- [ ] **Step 4: 記錄結果**

建立 `docs/superpowers/notes/2026-corpus-retention.md`，貼上 `retention.tsv` 內容，並針對留存率落在 30% 到 50% 之外的 repo 各寫一句原因。這份數字是階段三挑選主題群大小的依據。

- [ ] **Step 5: Commit**

```bash
git add docs/superpowers/notes/2026-corpus-retention.md
git commit -m "docs(corpus): 記錄各 repo 的實際篩選留存率"
```

---

### Task 6: 自家語料的取材

外部語料提供審查方法，自家語料定嚴重度標準。兩邊走同一條管線，差別只在第 2 步：
Acme repo 沒有 `author_association` 可用（大家都是 MEMBER），改用「近一年有 10 則
以上 review comment 的人」當資深判準。

**Files:**
- Create: `lib/corpus-internal.sh`
- Modify: `scripts/build-corpus.sh`（加 `--internal` 旗標）
- Test: `tests/test_corpus_internal.sh`

**Interfaces:**
- Consumes: Task 2 的 `corpus_fetch_repo`、`corpus_repo_dir`；Task 3 的 `corpus_filter_bots`、`corpus_filter_quality`、`corpus_filter_prose`、`corpus_project`
- Produces:
  - `corpus_internal_targets()` → stdout 一行一筆 `<owner/name>\t<layer>`
  - `corpus_active_reviewers <repo> [min_count]` → stdout 一行一個 login，近一年留言數達門檻者
  - `corpus_filter_active <reviewers_json>` → 取代 `corpus_filter_senior` 的第 2 步
  - `corpus_filter_all_internal <repo> <layer>` → 與 `corpus_filter_all` 同樣的 stdout / stderr 契約

- [ ] **Step 1: 寫失敗的測試**

建立 `tests/test_corpus_internal.sh`：

```bash
#!/usr/bin/env bash
# 自家語料取材 (lib/corpus-internal.sh)。
set -uo pipefail
MRA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
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

# 第 2 步改用活躍留言者清單，不看 author_association。
# fixture 裡 member1 有 4 則、member2 與 member3 各 1 則、outsider 1 則。
active='["member1"]'
eq "只留 member1" "[4,5,8,9]" "$(corpus_filter_bots < "$FX" | corpus_filter_active "$active" | jq -c '[.[].id]')"

# outsider 在 GitHub 上是 NONE，但只要留言夠多就該留下：
# 這正是自家 repo 與外部 repo 的差別。
active2='["member1","outsider"]'
eq "NONE 也能留下" "[3,4,5,8,9]" "$(corpus_filter_bots < "$FX" | corpus_filter_active "$active2" | jq -c '[.[].id]')"

# 完整管線的 stdout / stderr 契約與外部版一致
err="$(mktemp)"
outn="$(corpus_filter_all_internal acme/rails-app-1 rails "$active" < "$FX" 2>"$err" | jq 'length')"
# 留 2 筆（id 5、9）。id 4 短且無回覆無 reaction 被第 3 步濾掉，
# id 8 只有 suggestion 區塊沒有說明文字被第 4 步濾掉。
eq "自家管線留 2" "2" "$outn"
eq "自家管線 ids" "[5,9]" "$(corpus_filter_all_internal acme/rails-app-1 rails "$active" < "$FX" 2>/dev/null | jq -c '[.[].id]')"
case "$(cat "$err")" in RETENTION*acme/rails-app-1*) ok "留存數 TSV 格式一致" ;; *) fail "TSV 格式不對：$(cat "$err")" ;; esac
rm -f "$err"

echo "---"; echo "Passed: $pass"; echo "Failed: $errors"
exit $((errors > 0 ? 1 : 0))
```

- [ ] **Step 2: 跑測試確認失敗**

Run: `bash tests/test_corpus_internal.sh`
Expected: FAIL，訊息是 `lib/corpus-internal.sh: No such file or directory`

- [ ] **Step 3: 寫最小實作**

建立 `lib/corpus-internal.sh`：

```bash
#!/usr/bin/env bash
# 自家 Acme repo 的語料取材。
#
# 與外部語料共用抓取與第 1、3、4 步篩選，只有第 2 步不同：Acme repo 的成員
# author_association 幾乎都是 MEMBER，分不出資深與否，改用近一年的留言數。

corpus_internal_targets() {
  cat <<'EOF'
acme/rails-app-1	rails
acme/rails-app-2	rails
acme/rails-app-3	rails
acme/nest-monorepo-2.0	nestjs
acme/nest-app-2	nestjs
acme/nest-app-3	nestjs
acme/react-app-1	react
acme/react-app-2	react
acme/vue-app-1	vue
acme/vue-app-2	vue
EOF
}

# 近一年留言數達門檻的人。輸出是 JSON 陣列，直接餵給 corpus_filter_active。
corpus_active_reviewers() {
  local repo="$1" min="${2:-10}" page
  local all=""
  for page in 1 2 3; do
    all+="$(gh api "repos/$repo/pulls/comments?per_page=100&page=$page&sort=created&direction=desc" \
              --jq '.[].user.login' 2>/dev/null)"$'\n'
  done
  printf '%s' "$all" \
    | grep -v '^$' \
    | sort | uniq -c \
    | awk -v m="$min" '$1 >= m { print $2 }' \
    | jq -R . | jq -s -c .
}

corpus_filter_active() {
  local reviewers="$1"
  jq --argjson active "$reviewers" '[ .[] | select(.user.login as $u | $active | any(. == $u)) ]'
}

# 錯誤傳遞的規則與 corpus_filter_all 相同，理由見那邊的註解。
corpus_filter_all_internal() {
  local repo="$1" layer="$2" reviewers="$3"
  local s0 s1 s2 s3 s4
  s0="$(cat)"

  if ! printf '%s' "$s0" | jq -e 'type == "array"' >/dev/null 2>&1; then
    printf 'FILTER_INPUT_INVALID\t%s\n' "$repo" >&2
    return 1
  fi

  s1="$(printf '%s' "$s0" | corpus_filter_bots)" \
    || { printf 'FILTER_STAGE_FAILED\t%s\tbots\n' "$repo" >&2; return 1; }
  s2="$(printf '%s' "$s1" | corpus_filter_active "$reviewers")" \
    || { printf 'FILTER_STAGE_FAILED\t%s\tactive\n' "$repo" >&2; return 1; }
  s3="$(printf '%s' "$s2" | corpus_filter_quality)" \
    || { printf 'FILTER_STAGE_FAILED\t%s\tquality\n' "$repo" >&2; return 1; }
  s4="$(printf '%s' "$s3" | corpus_filter_prose)" \
    || { printf 'FILTER_STAGE_FAILED\t%s\tprose\n' "$repo" >&2; return 1; }
  printf 'RETENTION\t%s\t%s\t%s\t%s\t%s\t%s\n' "$repo" \
    "$(printf '%s' "$s0" | jq 'length')" \
    "$(printf '%s' "$s1" | jq 'length')" \
    "$(printf '%s' "$s2" | jq 'length')" \
    "$(printf '%s' "$s3" | jq 'length')" \
    "$(printf '%s' "$s4" | jq 'length')" >&2
  printf '%s' "$s4" | corpus_project "$repo" "$layer"
}
```

- [ ] **Step 4: 跑測試確認通過**

Run: `bash tests/test_corpus_internal.sh`
Expected: PASS，`Failed: 0`

- [ ] **Step 5: 讓 CLI 支援 `--internal`**

修改 `scripts/build-corpus.sh`。在參數解析加一個旗標：

```bash
    --internal)    INTERNAL=1; shift ;;
```

在檔案開頭的變數初始化加 `INTERNAL=0`，並在 `source` 區塊加上：

```bash
source "$MRA_DIR/lib/corpus-internal.sh"
```

把選目標的那段改成：

```bash
if [[ -n "$ONLY_REPO" ]]; then
  if [[ "$INTERNAL" == 1 ]]; then
    layer="$(corpus_internal_targets | awk -F'\t' -v r="$ONLY_REPO" '$1==r{print $2; f=1} END{exit !f}')" || {
      echo "不在自家目標清單中的 repo：$ONLY_REPO" >&2; exit 1; }
  elif ! layer="$(corpus_layer_of "$ONLY_REPO")"; then
    echo "不在目標清單中的 repo：$ONLY_REPO" >&2
    exit 1
  fi
  targets="$(printf '%s\t%s\n' "$ONLY_REPO" "$layer")"
elif [[ "$INTERNAL" == 1 ]]; then
  targets="$(corpus_internal_targets)"
else
  targets="$(corpus_targets)"
fi
```

把篩選那段的管線改成依 `INTERNAL` 分流：

```bash
    if [[ "$INTERNAL" == 1 ]]; then
      reviewers="$(corpus_active_reviewers "$repo" 10)"
      jq -s 'add' "${pages[@]}" \
        | corpus_filter_all_internal "$repo" "$layer" "$reviewers" 2>"$err" \
        > "$dir/filtered.json"
    else
      jq -s 'add' "${pages[@]}" \
        | corpus_filter_all "$repo" "$layer" 2>"$err" \
        > "$dir/filtered.json"
    fi
```

- [ ] **Step 6: 跑全套測試**

Run: `make test`
Expected: 全數通過

- [ ] **Step 7: lint**

Run: `shellcheck -S warning lib/corpus-internal.sh scripts/build-corpus.sh tests/test_corpus_internal.sh`
Expected: 無輸出

- [ ] **Step 8: 對真實的自家 repo 跑一次**

需要先切到有 acme org 權限的帳號：

```bash
gh auth switch --user acme-bot
bash scripts/build-corpus.sh --internal --repo acme/rails-app-1
gh auth switch --user hanfour
```

Expected: `retention.tsv` 出現 `acme/rails-app-1` 那列。`erp` 近一年 355 個 PR，語料量應該是各自家 repo 中最大的。

- [ ] **Step 9: Commit**

```bash
git add lib/corpus-internal.sh scripts/build-corpus.sh tests/test_corpus_internal.sh
git commit -m "feat(corpus): 自家 repo 語料取材"
```
