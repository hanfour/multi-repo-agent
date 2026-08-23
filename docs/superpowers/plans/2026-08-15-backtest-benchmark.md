# 階段二：回測基準集 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 造出一組有 ground truth 的舊 PR 基準集，並用現有 persona 跑出基準線數字，讓階段四的新規則有東西可以比。

**Architecture:** 以「PR 合併後 14 天內有 fix commit 改到同一檔案且行號區間重疊」找出候選，人工確認後成為基準集。指標計算讀 `mra review` 的既有輸出格式，不改 review 流程本身。

**Tech Stack:** bash、`gh` CLI、jq 1.8、`mra review --strategy personas`。

**Spec:** `docs/superpowers/specs/2026-08-14-team-code-review-ruleset-design.md`

## Global Constraints

- 基準集存 `${MRA_BENCHMARK_DIR:-$HOME/.cache/mra-review-benchmark}`，不進 git。人工確認結果存 `benchmark.json` 並手動複製一份到 `tests/fixtures/backtest/` 供測試使用。
- 讀 acme org 需要 `gh auth switch --user acme-bot`，跑完切回 `hanfour`。腳本不自行切換帳號，只在權限不足時明確報錯。
- 回測不得 post 到 PR。`run-backtest.sh` 一律走輸出存檔比對。
- `mra review` 的輸出格式以 `schemas/review-result.schema.json` 為準：`{status, summary, comments:[{path, line, body, severity}]}`，severity 值域 `CRITICAL / HIGH / MEDIUM / LOW`。
- 所有新檔案要通過 `make lint`（shellcheck `-S warning`）。lint 閘門現在涵蓋 `lib/`、`bin/`、
  `tests/`、`scripts/` 四處；新增其他目錄要同步改 `Makefile` 與 `.github/workflows/repo-tests.yml`，
  `tests/test_lint_gate.sh` 會驗兩邊的檔案集一致。

### 階段一付過代價換來的約束

以下每一條都對應階段一實際發生過的缺陷，不是預防性的清單。違反任何一條都會重現已知的失敗。

- **新增的 `lib/*.sh` 一定要註冊進 `bin/mra.sh` 的 `MRA_LIBS`。** `tests/test_lib_loader.sh` 會驗
  （issue #39：那是明確排序清單不是 glob，忘記註冊的 lib 在執行期靜默缺席）。
- **不得用 `awk -v var="$值"` 傳任意字串。** awk 的 `-v` 會先處理反斜線跳脫，`rails\/rails`（12 位元組）
  會被收合成 `rails/rails`（11 位元組）而誤配，含換行的值直接讓 awk crash。用
  `var="$值" awk '... ENVIRON["var"] ...'`。
- **不得用無參數的 `mktemp`。** macOS/BSD 的 bare `mktemp` 走 `_CS_DARWIN_USER_TEMP_DIR`、忽略
  `TMPDIR`，會讓任何「不洩漏暫存檔」的斷言變成永遠不會失敗的空斷言。一律
  `mktemp "${TMPDIR:-/tmp}/名稱.XXXXXX"`。
- **所有寫入型動作都要檢查退出碼**，包含 `mv`。階段一有三個 `mv` 各自造成一次「回報成功但檔案沒寫進去、
  暫存檔洩漏」，前兩個修掉之後第三個仍然出貨。
- **每一種失敗都要有自己的開頭 token**，不得把失敗塞進成功形狀的訊息裡。階段一的
  `DONE ... failed=6` 讓 10 頁語料悄悄消失且驗收文件回報完整。既有 token：`RATE_LIMIT_STOP`、
  `RATE_CHECK_FAILED`、`FETCH_INCOMPLETE`、`CACHE_INCOMPLETE`、`FILTER_INPUT_INVALID`、
  `FILTER_STAGE_FAILED`、`FILTER_PROMOTE_FAILED`、`LAST_PAGE_UNKNOWN`、`NOT_ATTEMPTED`、
  `ACTIVE_REVIEWERS_FETCH_FAILED`、`ACTIVE_REVIEWERS_PARTIAL`。
- **`local x="$(cmd)"` 的 `$?` 恆為 0**（`local` 本身是指令，退出碼蓋掉命令替換的）。需要判斷退出碼時
  先宣告再指派。同理 `if ! out="$(cmd)"; then status=$?` 拿到的是 0 不是原始退出碼，要寫成 if/else。
- **jq 解析失敗的退出碼是 5 不是 1**，用 `|| return 1` 判斷，不要比對特定數值。
- **每個 task 收尾時要把本 task 產生的 ruling 套到全 repo。** 階段一有四條 ruling 判斷正確但只套用在
  發現它的位置，兄弟位置要等最終 review 才被抓到。

## 一個已知的判定誤差

檔案層級的重疊太寬。實測 `acme/rails-app-1` 近 40 個 merged PR：

| 判定方式 | 命中 | 命中率 |
| --- | --- | --- |
| 只看有沒有 fix commit 動到同一個檔案 | 9 / 40 | 22.5% |
| 加上行號區間重疊 | 5 / 40 | 12.5% |

行號判定砍掉 44% 的噪音，那些是 Rails controller 的日常改動，不是缺陷證據。即使收緊到行號，候選集仍要人工確認才能當 ground truth，Task 4 不是可省略的步驟。

依 12.5% 推算基準集規模：四個主力 repo（`erp` 355、`nest-monorepo-2.0` 349、`react-app-1` 206、`finance-system` 194）近一年約 1,100 個 PR，可產出約 137 個候選。人工確認後估計留下 70 到 95 個，足以支撐 spec 要求的 30 到 40 個基準 PR。

另一個誤差來源：團隊用 `fix(scope):` 當 PR 標題慣例，所以 PR 自己的 merge commit 會被誤判成「修這個 PR 的 commit」。判定時要排除該 PR 的 `merge_commit_sha`，以及 message 裡帶 `#<PR 編號>` 的 commit。

---

### Task 1: patch 的行號區間解析與交集

**Files:**
- Create: `lib/backtest-hunks.sh`
- Test: `tests/test_backtest_hunks.sh`

**Interfaces:**
- Consumes: 無
- Produces:
  - `backtest_hunks_of` → stdin 是 patch 文字，stdout 一行一個 `<起> <迄>`（新檔側行號，含頭含尾）
  - `backtest_ranges_overlap <ranges_a> <ranges_b>` → 兩組多行區間有交集時退出碼 0，否則非 0

> 後記（2026-08-23）：`backtest_ranges_overlap` 實作出來之後沒有任何呼叫端，
> 正式路徑走的是 `lib/backtest-hunks.sh` 的 `backtest_overlap`（由
> `scripts/build-benchmark.sh` 呼叫）。它連同 13 支只測它的斷言已在階段三
> 收尾時刪除，那些斷言真正還缺的覆蓋深度搬進了
> `tests/test_backtest_groundtruth.sh`。這一段保留原樣是當時的計畫紀錄，
> 不是現在的介面。

- [ ] **Step 1: 寫失敗的測試**

建立 `tests/test_backtest_hunks.sh`：

```bash
#!/usr/bin/env bash
# patch 行號區間解析與交集 (lib/backtest-hunks.sh)。
set -uo pipefail
MRA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$MRA_DIR/lib/backtest-hunks.sh"

errors=0; pass=0
ok()   { echo "PASS: $1"; pass=$((pass+1)); }
fail() { echo "FAIL: $1"; errors=$((errors+1)); }
eq()   { if [[ "$2" == "$3" ]]; then ok "$1"; else fail "$1 — expected [$2] got [$3]"; fi; }

# 取自 acme/rails-app-1#4919 的真實 hunk header
patch=$(cat <<'P'
@@ -92,7 +92,7 @@ def update
           record.from_sales_id,
@@ -44,6 +44,6 @@ class Foo
   something
@@ -153,20 +153,23 @@ def bar
   other
P
)
eq "三個區間" "92 98
44 49
153 175" "$(printf '%s\n' "$patch" | backtest_hunks_of)"

# 沒有長度的 hunk header 視為一行
eq "單行 hunk" "10 10" "$(printf '@@ -10 +10 @@\n' | backtest_hunks_of)"

# 新增檔案：舊側是 0,0
eq "新檔整段" "1 25" "$(printf '@@ -0,0 +1,25 @@\n' | backtest_hunks_of)"

# 非 patch 內容不產生區間
eq "無 hunk" "" "$(printf 'no hunks here\n' | backtest_hunks_of)"

# --- 交集
if backtest_ranges_overlap "10 20" "15 25"; then ok "部分重疊"; else fail "部分重疊應為真"; fi
if backtest_ranges_overlap "10 20" "20 30"; then ok "端點相接算重疊"; else fail "端點相接應為真"; fi
if backtest_ranges_overlap "10 20" "21 30"; then fail "相鄰不應算重疊"; else ok "相鄰不算重疊"; fi
if backtest_ranges_overlap "1 5
100 110" "105 120"; then ok "多區間任一重疊即為真"; else fail "多區間應為真"; fi
if backtest_ranges_overlap "1 5" "10 20
30 40"; then fail "全不重疊應為假"; else ok "全不重疊為假"; fi
if backtest_ranges_overlap "" "10 20"; then fail "空區間應為假"; else ok "空區間為假"; fi
if backtest_ranges_overlap "10 20" ""; then fail "空區間應為假"; else ok "空區間為假(反向)"; fi

echo "---"; echo "Passed: $pass"; echo "Failed: $errors"
exit $((errors > 0 ? 1 : 0))
```

- [ ] **Step 2: 跑測試確認失敗**

Run: `bash tests/test_backtest_hunks.sh`
Expected: FAIL，訊息是 `lib/backtest-hunks.sh: No such file or directory`

- [ ] **Step 3: 寫最小實作**

建立 `lib/backtest-hunks.sh`：

```bash
#!/usr/bin/env bash
# 從 unified diff 的 hunk header 取出新檔側的行號區間，並判斷兩組區間有無交集。
#
# hunk header 形如 `@@ -92,7 +92,7 @@`。省略長度時（`@@ -10 +10 @@`）長度為 1。
# 只看新檔側（+ 那一半），因為要問的是「後來的 fix 改到了這個 PR 新寫的哪幾行」。

backtest_hunks_of() {
  grep -oE '^@@ -[0-9,]+ \+[0-9]+(,[0-9]+)? @@' \
    | sed -E 's/^@@ -[0-9,]+ \+([0-9]+)(,([0-9]+))? @@/\1 \3/' \
    | awk '{ len = ($2 == "" ? 1 : $2); print $1, $1 + len - 1 }'
}

# B 用分號串接再透過 ENVIRON 傳給 awk。兩個原因：
#   1. 不能傳多行字串。macOS 的 awk 會報 `newline in string`，整個判斷靜默失效，
#      重疊一律變成「否」，而且不會有錯誤訊息。
#   2. 用 ENVIRON 而不是 -v。這裡的值只有數字與分號，-v 的反斜線跳脫咬不到，
#      但全 repo 一律不用 -v 傳計算出來的字串，不留「這裡可以」的例外給人抄。
backtest_ranges_overlap() {
  local a="$1" b="$2"
  [[ -z "$a" || -z "$b" ]] && return 1
  BT_RANGES_B="$(printf '%s' "$b" | tr '\n' ';')" awk '
    BEGIN {
      n = split(ENVIRON["BT_RANGES_B"], lines, ";")
      for (i = 1; i <= n; i++) {
        if (lines[i] == "") continue
        split(lines[i], p, " "); bs[i] = p[1]; be[i] = p[2]
      }
    }
    NF == 2 {
      for (i = 1; i <= n; i++)
        if (bs[i] != "" && $1 <= be[i] && bs[i] <= $2) { found = 1; exit }
    }
    END { exit !found }
  ' <<< "$a"
}
```

- [ ] **Step 4: 跑測試確認通過**

Run: `bash tests/test_backtest_hunks.sh`
Expected: PASS，`Failed: 0`

- [ ] **Step 5: lint**

Run: `shellcheck -S warning lib/backtest-hunks.sh tests/test_backtest_hunks.sh`
Expected: 無輸出

- [ ] **Step 6: Commit**

```bash
git add lib/backtest-hunks.sh tests/test_backtest_hunks.sh
git commit -m "feat(backtest): patch 行號區間解析與交集"
```

---

### Task 2: ground truth 候選判定

**Files:**
- Create: `lib/backtest-groundtruth.sh`
- Test: `tests/test_backtest_groundtruth.sh`

**Interfaces:**
- Consumes: Task 1 的 `backtest_hunks_of`、`backtest_ranges_overlap`
- Produces:
  - `backtest_merged_prs <repo> [limit]` → JSON 陣列 `[{n, merged_at, merge_commit_sha}]`
  - `backtest_window_end <iso8601> [days]` → 視窗結束時間字串
  - `backtest_fix_commits <repo> <pr_number> <merged_at> <own_sha> [days]` → JSON 陣列 `[{sha, message}]`，已排除該 PR 自己的 merge commit 與 message 帶 `#<pr>` 的 commit
  - `backtest_pr_ranges <repo> <pr_number>` → JSON 物件 `{"<path>": [[起,迄], ...]}`
  - `backtest_commit_ranges <repo> <sha>` → 同上格式
  - `backtest_overlap <ranges_json_a> <ranges_json_b>` → JSON 陣列，列出重疊的 `{path, pr_range, fix_range}`；無重疊時輸出 `[]`

- [ ] **Step 1: 寫失敗的測試**

建立 `tests/test_backtest_groundtruth.sh`：

```bash
#!/usr/bin/env bash
# ground truth 候選判定 (lib/backtest-groundtruth.sh)。用 PATH shim 假造 gh。
set -uo pipefail
MRA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$MRA_DIR/lib/backtest-hunks.sh"

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin"
cat > "$TMP/bin/gh" <<'SHIM'
#!/usr/bin/env bash
case "$*" in
  *"pulls/4919/files"*)
    printf '%s' '[{"filename":"app/a.rb","patch":"@@ -92,7 +92,7 @@ def update\n x"},
                  {"filename":"app/b.rb","patch":"@@ -10,5 +10,5 @@ def x\n y"}]' ;;
  *"commits/aaa111"*)
    printf '%s' '{"files":[{"filename":"app/a.rb","patch":"@@ -95,2 +95,4 @@ def update\n z"}]}' ;;
  *"commits/bbb222"*)
    printf '%s' '{"files":[{"filename":"app/c.rb","patch":"@@ -1,2 +1,2 @@\n w"}]}' ;;
  *"commits?since"*|*"commits?"*)
    printf '%s' '[{"sha":"own999","commit":{"message":"fix(x): the PR itself (#4919)"}},
                  {"sha":"aaa111","commit":{"message":"fix(y): overlapping fix"}},
                  {"sha":"bbb222","commit":{"message":"fix(z): unrelated file"}},
                  {"sha":"ccc333","commit":{"message":"feat(w): not a fix"}}]' ;;
  *"pulls?state=closed"*)
    printf '%s' '[{"number":4919,"merged_at":"2026-08-10T09:09:52Z","merge_commit_sha":"own999"},
                  {"number":4918,"merged_at":null,"merge_commit_sha":null}]' ;;
esac
exit 0
SHIM
chmod +x "$TMP/bin/gh"; export PATH="$TMP/bin:$PATH"

source "$MRA_DIR/lib/backtest-groundtruth.sh"

errors=0; pass=0
ok()   { echo "PASS: $1"; pass=$((pass+1)); }
fail() { echo "FAIL: $1"; errors=$((errors+1)); }
eq()   { if [[ "$2" == "$3" ]]; then ok "$1"; else fail "$1 — expected [$2] got [$3]"; fi; }

eq "只取 merged" "[4919]" "$(backtest_merged_prs acme/rails-app-1 10 | jq -c '[.[].n]')"
eq "14 天視窗" "2026-08-24T09:09:52Z" "$(backtest_window_end 2026-08-10T09:09:52Z 14)"
eq "7 天視窗"  "2026-08-17T09:09:52Z" "$(backtest_window_end 2026-08-10T09:09:52Z 7)"

# 排除自己的 merge commit(own999)、帶 #4919 的 commit、以及非 fix 的 commit
eq "候選 fix commit" '["aaa111","bbb222"]' \
  "$(backtest_fix_commits acme/rails-app-1 4919 2026-08-10T09:09:52Z own999 14 | jq -c '[.[].sha]')"

eq "PR 的區間" '{"app/a.rb":[[92,98]],"app/b.rb":[[10,14]]}' \
  "$(backtest_pr_ranges acme/rails-app-1 4919 | jq -cS .)"
eq "commit 的區間" '{"app/a.rb":[[95,98]]}' \
  "$(backtest_commit_ranges acme/rails-app-1 aaa111 | jq -cS .)"

# aaa111 改到 app/a.rb 的 95-98,與 PR 的 92-98 重疊
a="$(backtest_pr_ranges acme/rails-app-1 4919)"
b="$(backtest_commit_ranges acme/rails-app-1 aaa111)"
eq "重疊一筆"   "1"          "$(backtest_overlap "$a" "$b" | jq 'length')"
eq "重疊在 a.rb" '"app/a.rb"' "$(backtest_overlap "$a" "$b" | jq -c '.[0].path')"

# bbb222 只動 app/c.rb,PR 沒碰過
c="$(backtest_commit_ranges acme/rails-app-1 bbb222)"
eq "不同檔案不重疊" "[]" "$(backtest_overlap "$a" "$c" | jq -c .)"

echo "---"; echo "Passed: $pass"; echo "Failed: $errors"
exit $((errors > 0 ? 1 : 0))
```

- [ ] **Step 2: 跑測試確認失敗**

Run: `bash tests/test_backtest_groundtruth.sh`
Expected: FAIL，訊息是 `lib/backtest-groundtruth.sh: No such file or directory`

- [ ] **Step 3: 寫最小實作**

建立 `lib/backtest-groundtruth.sh`：

```bash
#!/usr/bin/env bash
# 回測基準集的 ground truth 候選判定。
#
# 判定：PR 合併後 N 天內，有 message 含 fix/hotfix/bug 的 commit 改到同一檔案，
# 且行號區間與 PR 的改動重疊。
#
# 兩個必要的排除，否則會把 PR 自己算成「修自己的 commit」：
#   1. 該 PR 的 merge_commit_sha
#   2. message 裡帶 `#<PR 編號>` 的 commit
# 團隊用 `fix(scope):` 當 PR 標題慣例，所以 PR 自己的 merge commit 一定長得像
# 一個 fix commit。
#
# 這個判定只產出「候選」。檔案層級的重疊實測太寬（acme/rails-app-1 近 40 個 PR 至少
# 9 個命中，多數是日常改動），行號層級收緊後仍需人工確認，見 Task 4。

backtest_merged_prs() {
  local repo="$1" limit="${2:-100}"
  gh api "repos/$repo/pulls?state=closed&per_page=$limit&sort=updated&direction=desc" \
    --jq '[ .[] | select(.merged_at != null)
            | {n: .number, merged_at: .merged_at, merge_commit_sha: .merge_commit_sha} ]' \
    2>/dev/null
}

backtest_window_end() {
  local start="$1" days="${2:-14}"
  python3 -c "
import datetime, sys
d = datetime.datetime.strptime(sys.argv[1], '%Y-%m-%dT%H:%M:%SZ')
print((d + datetime.timedelta(days=int(sys.argv[2]))).strftime('%Y-%m-%dT%H:%M:%SZ'))
" "$start" "$days"
}

backtest_fix_commits() {
  local repo="$1" pr="$2" merged="$3" own="$4" days="${5:-14}"
  local until; until="$(backtest_window_end "$merged" "$days")"
  # gh api 的 --jq 不接受 --arg，所以這裡 pipe 給 jq 而不是用 --jq。
  gh api "repos/$repo/commits?since=$merged&until=$until&per_page=100" 2>/dev/null \
    | jq --arg own "$own" --arg pr "$pr" '
      [ .[]
        | select(.sha != $own)
        | select(.commit.message | test("fix|hotfix|bug"; "i"))
        | select(.commit.message | test("#" + $pr + "\\b") | not)
        | {sha: .sha, message: (.commit.message | split("\n")[0])} ]'
}

# 內部用：把 [{filename, patch}] 轉成 {"<path>": [[起,迄], ...]}
_backtest_ranges_from_files() {
  local files_json="$1"
  local out='{}' path patch ranges
  while IFS= read -r path; do
    [[ -z "$path" ]] && continue
    patch="$(printf '%s' "$files_json" | jq -r --arg p "$path" '.[] | select(.filename == $p) | .patch // ""')"
    ranges="$(printf '%s\n' "$patch" | backtest_hunks_of \
      | awk 'NF == 2 { printf "[%s,%s],", $1, $2 }' | sed 's/,$//')"
    [[ -z "$ranges" ]] && continue
    out="$(printf '%s' "$out" | jq --arg p "$path" --argjson r "[$ranges]" '. + {($p): $r}')"
  done < <(printf '%s' "$files_json" | jq -r '.[].filename')
  printf '%s' "$out"
}

backtest_pr_ranges() {
  local repo="$1" pr="$2" files
  files="$(gh api "repos/$repo/pulls/$pr/files?per_page=100" 2>/dev/null)" || return 1
  _backtest_ranges_from_files "$files"
}

backtest_commit_ranges() {
  local repo="$1" sha="$2" files
  files="$(gh api "repos/$repo/commits/$sha" --jq '.files' 2>/dev/null)" || return 1
  _backtest_ranges_from_files "$files"
}

backtest_overlap() {
  local a="$1" b="$2"
  jq -n --argjson a "$a" --argjson b "$b" '
    [ ($a | to_entries[]) as $pa
      | ($b[$pa.key] // []) as $bl
      | $pa.value[] as $ra
      | $bl[] as $rb
      | select($ra[0] <= $rb[1] and $rb[0] <= $ra[1])
      | {path: $pa.key, pr_range: $ra, fix_range: $rb} ]'
}
```

- [ ] **Step 4: 跑測試確認通過**

Run: `bash tests/test_backtest_groundtruth.sh`
Expected: PASS，`Failed: 0`

- [ ] **Step 5: lint**

Run: `shellcheck -S warning lib/backtest-groundtruth.sh tests/test_backtest_groundtruth.sh`
Expected: 無輸出

- [ ] **Step 6: Commit**

```bash
git add lib/backtest-groundtruth.sh tests/test_backtest_groundtruth.sh
git commit -m "feat(backtest): ground truth 候選判定"
```

---

### Task 3: 基準集候選建構 CLI

**Files:**
- Create: `scripts/build-benchmark.sh`
- Test: `tests/test_build_benchmark.sh`

**Interfaces:**
- Consumes: Task 1、Task 2 的全部函式
- Produces:
  - `scripts/build-benchmark.sh --repo <owner/name> [--limit N] [--days N]`
  - 輸出 `${MRA_BENCHMARK_DIR:-$HOME/.cache/mra-review-benchmark}/candidates.json`
  - 每筆結構：

```json
{
  "repo": "acme/rails-app-1",
  "pr": 4919,
  "merged_at": "2026-08-10T09:09:52Z",
  "fix_commits": [
    {"sha": "aaa111", "message": "fix(y): ...",
     "overlaps": [{"path": "app/a.rb", "pr_range": [92,98], "fix_range": [95,98]}]}
  ],
  "confirmed": null,
  "expected_findings": []
}
```

`confirmed` 是 Task 4 人工填的三態欄位：`true` 確認是缺陷、`false` 誤收、`null` 未審。

- [ ] **Step 1: 寫失敗的測試**

建立 `tests/test_build_benchmark.sh`。沿用 Task 2 測試的同一份 `gh` shim（複製那段 SHIM heredoc 過來，不要 source 另一個測試檔）：

```bash
#!/usr/bin/env bash
# 基準集候選建構 (scripts/build-benchmark.sh)。
set -uo pipefail
MRA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export MRA_BENCHMARK_DIR="$TMP/bench"
mkdir -p "$TMP/bin"
cat > "$TMP/bin/gh" <<'SHIM'
#!/usr/bin/env bash
case "$*" in
  *"pulls/4919/files"*)
    printf '%s' '[{"filename":"app/a.rb","patch":"@@ -92,7 +92,7 @@ def update\n x"},
                  {"filename":"app/b.rb","patch":"@@ -10,5 +10,5 @@ def x\n y"}]' ;;
  *"commits/aaa111"*)
    printf '%s' '{"files":[{"filename":"app/a.rb","patch":"@@ -95,2 +95,4 @@ def update\n z"}]}' ;;
  *"commits/bbb222"*)
    printf '%s' '{"files":[{"filename":"app/c.rb","patch":"@@ -1,2 +1,2 @@\n w"}]}' ;;
  *"commits?since"*|*"commits?"*)
    printf '%s' '[{"sha":"own999","commit":{"message":"fix(x): the PR itself (#4919)"}},
                  {"sha":"aaa111","commit":{"message":"fix(y): overlapping fix"}},
                  {"sha":"bbb222","commit":{"message":"fix(z): unrelated file"}}]' ;;
  *"pulls?state=closed"*)
    printf '%s' '[{"number":4919,"merged_at":"2026-08-10T09:09:52Z","merge_commit_sha":"own999"}]' ;;
esac
exit 0
SHIM
chmod +x "$TMP/bin/gh"; export PATH="$TMP/bin:$PATH"

errors=0; pass=0
ok()   { echo "PASS: $1"; pass=$((pass+1)); }
fail() { echo "FAIL: $1"; errors=$((errors+1)); }
eq()   { if [[ "$2" == "$3" ]]; then ok "$1"; else fail "$1 — expected [$2] got [$3]"; fi; }

bash "$MRA_DIR/scripts/build-benchmark.sh" --repo acme/rails-app-1 --limit 10 >/dev/null 2>&1
eq "退出碼 0" "0" "$?"

C="$TMP/bench/candidates.json"
if [[ -s "$C" ]]; then ok "candidates.json 產出"; else fail "candidates.json 沒產出"; fi
eq "一個候選 PR"     "1"          "$(jq 'length' "$C")"
eq "PR 編號"         "4919"       "$(jq -r '.[0].pr' "$C")"
eq "只留有重疊的 fix" '["aaa111"]' "$(jq -c '[.[0].fix_commits[].sha]' "$C")"
eq "重疊落在 a.rb"    '"app/a.rb"' "$(jq -c '.[0].fix_commits[0].overlaps[0].path' "$C")"
eq "confirmed 預設 null" "null"    "$(jq -r '.[0].confirmed' "$C")"
eq "expected_findings 預設空" "0"  "$(jq '.[0].expected_findings | length' "$C")"

# 重跑不覆蓋已填的 confirmed
jq '.[0].confirmed = true' "$C" > "$C.tmp" && mv "$C.tmp" "$C"
bash "$MRA_DIR/scripts/build-benchmark.sh" --repo acme/rails-app-1 --limit 10 >/dev/null 2>&1
eq "重跑保留人工結果" "true" "$(jq -r '.[0].confirmed' "$C")"

echo "---"; echo "Passed: $pass"; echo "Failed: $errors"
exit $((errors > 0 ? 1 : 0))
```

- [ ] **Step 2: 跑測試確認失敗**

Run: `bash tests/test_build_benchmark.sh`
Expected: FAIL，訊息是 `scripts/build-benchmark.sh: No such file or directory`

- [ ] **Step 3: 寫最小實作**

建立 `scripts/build-benchmark.sh`：

```bash
#!/usr/bin/env bash
# 建構回測基準集的候選清單。
#
# 只產出候選。人工確認在 Task 4，重跑時已填的 confirmed 與 expected_findings
# 會保留，不會被覆蓋。
set -uo pipefail

MRA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$MRA_DIR/lib/backtest-hunks.sh"
source "$MRA_DIR/lib/backtest-groundtruth.sh"

REPO=""; LIMIT=100; DAYS=14
while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo)  REPO="$2"; shift 2 ;;
    --limit) LIMIT="$2"; shift 2 ;;
    --days)  DAYS="$2"; shift 2 ;;
    -h|--help)
      echo "用法: build-benchmark.sh --repo <owner/name> [--limit N] [--days N]"
      exit 0 ;;
    *) echo "未知參數：$1" >&2; exit 1 ;;
  esac
done
[[ -z "$REPO" ]] && { echo "缺 --repo" >&2; exit 1; }

BENCH_DIR="${MRA_BENCHMARK_DIR:-$HOME/.cache/mra-review-benchmark}"
mkdir -p "$BENCH_DIR"
OUT="$BENCH_DIR/candidates.json"
[[ -f "$OUT" ]] || printf '[]' > "$OUT"

prs="$(backtest_merged_prs "$REPO" "$LIMIT")"
[[ -z "$prs" || "$prs" == "[]" ]] && { echo "沒有 merged PR：$REPO" >&2; exit 1; }

result='[]'
n_pr="$(printf '%s' "$prs" | jq 'length')"
for ((i = 0; i < n_pr; i++)); do
  pr="$(printf '%s' "$prs" | jq -r ".[$i].n")"
  merged="$(printf '%s' "$prs" | jq -r ".[$i].merged_at")"
  own="$(printf '%s' "$prs" | jq -r ".[$i].merge_commit_sha")"

  fixes="$(backtest_fix_commits "$REPO" "$pr" "$merged" "$own" "$DAYS")"
  [[ "$(printf '%s' "$fixes" | jq 'length')" -eq 0 ]] && continue

  pr_ranges="$(backtest_pr_ranges "$REPO" "$pr")" || continue
  [[ "$pr_ranges" == "{}" ]] && continue

  hits='[]'
  n_fix="$(printf '%s' "$fixes" | jq 'length')"
  for ((j = 0; j < n_fix; j++)); do
    sha="$(printf '%s' "$fixes" | jq -r ".[$j].sha")"
    msg="$(printf '%s' "$fixes" | jq -r ".[$j].message")"
    fix_ranges="$(backtest_commit_ranges "$REPO" "$sha")" || continue
    ov="$(backtest_overlap "$pr_ranges" "$fix_ranges")"
    [[ "$(printf '%s' "$ov" | jq 'length')" -eq 0 ]] && continue
    hits="$(printf '%s' "$hits" | jq --arg s "$sha" --arg m "$msg" --argjson o "$ov" \
      '. + [{sha: $s, message: $m, overlaps: $o}]')"
  done

  [[ "$(printf '%s' "$hits" | jq 'length')" -eq 0 ]] && continue
  result="$(printf '%s' "$result" | jq \
    --arg repo "$REPO" --argjson pr "$pr" --arg merged "$merged" --argjson h "$hits" \
    '. + [{repo: $repo, pr: $pr, merged_at: $merged, fix_commits: $h,
           confirmed: null, expected_findings: []}]')"
done

# 合併：已存在的 (repo, pr) 保留舊的 confirmed 與 expected_findings
jq -s '
  (.[0] | map({key: (.repo + "#" + (.pr | tostring)), value: .}) | from_entries) as $old
  | .[1] | map(
      ($old[.repo + "#" + (.pr | tostring)]) as $prev
      | if $prev then .confirmed = $prev.confirmed
                      | .expected_findings = $prev.expected_findings
        else . end)
' "$OUT" <(printf '%s' "$result") > "$OUT.tmp" && mv "$OUT.tmp" "$OUT"

echo "候選 $(jq 'length' "$OUT") 筆 → $OUT"
echo "未確認 $(jq '[.[] | select(.confirmed == null)] | length' "$OUT") 筆，執行 Task 4 的人工確認"
```

- [ ] **Step 4: 跑測試確認通過**

Run: `bash tests/test_build_benchmark.sh`
Expected: PASS，`Failed: 0`

- [ ] **Step 5: lint**

Run: `shellcheck -S warning scripts/build-benchmark.sh tests/test_build_benchmark.sh`
Expected: 無輸出

- [ ] **Step 6: Commit**

```bash
git add scripts/build-benchmark.sh tests/test_build_benchmark.sh
git commit -m "feat(backtest): 基準集候選建構"
```

---

### Task 4: 人工確認基準集

候選不等於 ground truth。這一步把候選逐筆看過，判斷那個 fix commit 是不是在修這個
PR 引入的缺陷，並寫下「當初該抓到什麼」。這是階段二唯一無法自動化的步驟，也是整個
回測可信度的來源。

**Files:**
- Create: `scripts/review-benchmark.sh`（把候選整理成便於閱讀的形式）
- Create: `tests/fixtures/backtest/benchmark-sample.json`（確認完成後手動複製一份）
- Test: `tests/test_review_benchmark.sh`

**Interfaces:**
- Consumes: Task 3 產出的 `candidates.json`
- Produces:
  - `scripts/review-benchmark.sh [--next]` → 印出下一筆未確認候選的完整脈絡（PR 連結、fix commit 連結、重疊的檔案與行號）
  - `scripts/review-benchmark.sh --set <pr> <true|false>` → 寫入 `confirmed`
  - `scripts/review-benchmark.sh --add <pr> <path> <line> <severity> <note>` → 追加一筆 `expected_findings`。severity 值域同 `review-result.schema.json`：`CRITICAL / HIGH / MEDIUM / LOW`
  - `scripts/review-benchmark.sh --status` → 印出已確認 / 未確認 / 確認為缺陷的數量

- [ ] **Step 1: 寫失敗的測試**

建立 `tests/test_review_benchmark.sh`：

```bash
#!/usr/bin/env bash
# 人工確認工具 (scripts/review-benchmark.sh)。
set -uo pipefail
MRA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export MRA_BENCHMARK_DIR="$TMP/bench"
mkdir -p "$MRA_BENCHMARK_DIR"

cat > "$MRA_BENCHMARK_DIR/candidates.json" <<'J'
[
 {"repo":"acme/rails-app-1","pr":4919,"merged_at":"2026-08-10T09:09:52Z",
  "fix_commits":[{"sha":"aaa111","message":"fix(y): x",
                  "overlaps":[{"path":"app/a.rb","pr_range":[92,98],"fix_range":[95,98]}]}],
  "confirmed":null,"expected_findings":[]},
 {"repo":"acme/rails-app-1","pr":4911,"merged_at":"2026-08-01T00:00:00Z",
  "fix_commits":[{"sha":"bbb222","message":"fix(z): y",
                  "overlaps":[{"path":"app/b.rb","pr_range":[10,20],"fix_range":[15,18]}]}],
  "confirmed":null,"expected_findings":[]}
]
J

errors=0; pass=0
ok()   { echo "PASS: $1"; pass=$((pass+1)); }
fail() { echo "FAIL: $1"; errors=$((errors+1)); }
eq()   { if [[ "$2" == "$3" ]]; then ok "$1"; else fail "$1 — expected [$2] got [$3]"; fi; }
S="$MRA_DIR/scripts/review-benchmark.sh"
C="$MRA_BENCHMARK_DIR/candidates.json"

eq "初始狀態" "未確認 2 / 已確認 0 / 確認為缺陷 0" "$(bash "$S" --status)"

out="$(bash "$S" --next)"
case "$out" in *4919*) ok "--next 取最舊未確認的 4919" ;; *) fail "--next 內容不對：$out" ;; esac
case "$out" in *"app/a.rb"*) ok "--next 印出重疊檔案" ;; *) fail "缺重疊檔案" ;; esac
case "$out" in *"92"*"98"*) ok "--next 印出行號區間" ;; *) fail "缺行號區間" ;; esac
case "$out" in *"github.com/acme/rails-app-1/pull/4919"*) ok "--next 印出 PR 連結" ;; *) fail "缺 PR 連結" ;; esac
case "$out" in *"github.com/acme/rails-app-1/commit/aaa111"*) ok "--next 印出 commit 連結" ;; *) fail "缺 commit 連結" ;; esac

bash "$S" --set 4919 true >/dev/null
eq "寫入 confirmed" "true" "$(jq -r '.[] | select(.pr==4919) | .confirmed' "$C")"
eq "只動指定那筆" "null" "$(jq -r '.[] | select(.pr==4911) | .confirmed' "$C")"

bash "$S" --set 4911 false >/dev/null
eq "狀態更新" "未確認 0 / 已確認 2 / 確認為缺陷 1" "$(bash "$S" --status)"

bash "$S" --add 4919 app/a.rb 95 HIGH "回傳值沒判 nil" >/dev/null
eq "追加 finding" "1" "$(jq '.[] | select(.pr==4919) | .expected_findings | length' "$C")"
eq "finding 內容" '{"line":95,"note":"回傳值沒判 nil","path":"app/a.rb","severity":"HIGH"}' \
  "$(jq -cS '.[] | select(.pr==4919) | .expected_findings[0]' "$C")"

# 全部確認完之後 --next 要說完成，不要噴錯
out="$(bash "$S" --next)"; rc=$?
eq "全確認後退出 0" "0" "$rc"
case "$out" in *完成*|*沒有*) ok "--next 回報已無待確認" ;; *) fail "訊息不對：$out" ;; esac

# 未知 PR 要報錯
if bash "$S" --set 9999 true >/dev/null 2>&1; then fail "未知 PR 應退出非 0"; else ok "未知 PR 退出非 0"; fi

echo "---"; echo "Passed: $pass"; echo "Failed: $errors"
exit $((errors > 0 ? 1 : 0))
```

- [ ] **Step 2: 跑測試確認失敗**

Run: `bash tests/test_review_benchmark.sh`
Expected: FAIL，訊息是 `scripts/review-benchmark.sh: No such file or directory`

- [ ] **Step 3: 寫最小實作**

建立 `scripts/review-benchmark.sh`：

```bash
#!/usr/bin/env bash
# 基準集的人工確認工具。
#
# 候選是「PR 合併後有 fix commit 改到重疊行號」，這只是相關，不是因果。實測
# acme/rails-app-1 近 40 個 PR 用檔案層級判定有 9 個命中，其中多數是日常改動。所以每一筆
# 都要人看過，判斷那個 fix 是不是在修這個 PR 引入的問題。
set -uo pipefail

BENCH_DIR="${MRA_BENCHMARK_DIR:-$HOME/.cache/mra-review-benchmark}"
C="$BENCH_DIR/candidates.json"
[[ -f "$C" ]] || { echo "找不到 $C，先跑 scripts/build-benchmark.sh" >&2; exit 1; }

_write() { jq "$1" "$C" > "$C.tmp" && mv "$C.tmp" "$C"; }

_has_pr() { [[ "$(jq --argjson p "$1" '[.[] | select(.pr == $p)] | length' "$C")" -gt 0 ]]; }

case "${1:---next}" in
  --status)
    jq -r '
      "未確認 \([.[] | select(.confirmed == null)] | length)"
      + " / 已確認 \([.[] | select(.confirmed != null)] | length)"
      + " / 確認為缺陷 \([.[] | select(.confirmed == true)] | length)"' "$C"
    ;;

  --next)
    item="$(jq -c '[.[] | select(.confirmed == null)] | sort_by(.merged_at) | .[0] // empty' "$C")"
    if [[ -z "$item" ]]; then echo "沒有待確認的候選，確認完成"; exit 0; fi
    repo="$(printf '%s' "$item" | jq -r '.repo')"
    pr="$(printf '%s' "$item" | jq -r '.pr')"
    echo "PR      https://github.com/$repo/pull/$pr"
    echo "合併於  $(printf '%s' "$item" | jq -r '.merged_at')"
    printf '%s' "$item" | jq -r --arg repo "$repo" '
      .fix_commits[]
      | "fix     https://github.com/\($repo)/commit/\(.sha)\n        \(.message)",
        (.overlaps[] | "        重疊 \(.path)  PR \(.pr_range[0])-\(.pr_range[1])  fix \(.fix_range[0])-\(.fix_range[1])")'
    echo
    echo "判斷：這個 fix 是在修這個 PR 引入的缺陷嗎？"
    echo "  是 → scripts/review-benchmark.sh --set $pr true"
    echo "       再用 --add $pr <path> <line> <severity> <當初該抓到什麼> 記下期望的發現"
    echo "  否 → scripts/review-benchmark.sh --set $pr false"
    ;;

  --set)
    pr="$2"; val="$3"
    [[ "$val" == "true" || "$val" == "false" ]] || { echo "值必須是 true 或 false" >&2; exit 1; }
    _has_pr "$pr" || { echo "候選中沒有 PR $pr" >&2; exit 1; }
    _write "map(if .pr == $pr then .confirmed = $val else . end)"
    echo "PR $pr → confirmed=$val"
    ;;

  --add)
    pr="$2"; path="$3"; line="$4"; sev="$5"; note="$6"
    case "$sev" in CRITICAL|HIGH|MEDIUM|LOW) ;; *) echo "severity 必須是 CRITICAL/HIGH/MEDIUM/LOW" >&2; exit 1 ;; esac
    _has_pr "$pr" || { echo "候選中沒有 PR $pr" >&2; exit 1; }
    jq --argjson p "$pr" --arg path "$path" --argjson line "$line" --arg sev "$sev" --arg note "$note" '
      map(if .pr == $p
          then .expected_findings += [{path: $path, line: $line, severity: $sev, note: $note}]
          else . end)' "$C" > "$C.tmp" && mv "$C.tmp" "$C"
    echo "PR $pr 追加 finding：$path:$line [$sev]"
    ;;

  -h|--help)
    echo "用法: review-benchmark.sh [--next | --status | --set <pr> <true|false> | --add <pr> <path> <line> <severity> <note>]"
    ;;
  *) echo "未知參數：$1" >&2; exit 1 ;;
esac
```

- [ ] **Step 4: 跑測試確認通過**

Run: `bash tests/test_review_benchmark.sh`
Expected: PASS，`Failed: 0`

- [ ] **Step 5: lint**

Run: `shellcheck -S warning scripts/review-benchmark.sh tests/test_review_benchmark.sh`
Expected: 無輸出

- [ ] **Step 6: Commit**

```bash
git add scripts/review-benchmark.sh tests/test_review_benchmark.sh
git commit -m "feat(backtest): 基準集人工確認工具"
```

---

### Task 5: 指標計算

**Files:**
- Create: `lib/backtest-metrics.sh`
- Test: `tests/test_backtest_metrics.sh`

**Interfaces:**
- Consumes: Task 4 確認過的 `candidates.json`；`mra review` 的輸出（`schemas/review-result.schema.json`）
- Produces:
  - `backtest_match <review_json> <expected_json> [tolerance]` → JSON 陣列，每筆 `{expected, matched: <comment 或 null>}`；`tolerance` 是行號容差，預設 5
  - `backtest_metrics <matches_json> <review_json>` → JSON 物件 `{expected_total, missed, miss_rate, comments_total, unmatched, unmatched_rate, severity_agree, severity_rate}`

三個指標的定義與各自的限制：

| 指標 | 算法 | 限制 |
| --- | --- | --- |
| 漏抓率 `miss_rate` | 沒被任何 comment 命中的 expected finding 佔比 | 只涵蓋人工確認過的缺陷，涵蓋不到基準集沒收錄的 |
| 未對應率 `unmatched_rate` | 沒對應到任何 expected finding 的 comment 佔比 | 這不等於誤報。review 找到基準集沒收錄的真問題也會算進來，所以只能看趨勢不能看絕對值 |
| 嚴重度吻合率 `severity_rate` | 命中的 comment 中 severity 與人工標註相同的佔比 | 分母是命中數，命中太少時這個數字沒有意義 |

- [ ] **Step 1: 寫失敗的測試**

建立 `tests/test_backtest_metrics.sh`：

```bash
#!/usr/bin/env bash
# 回測指標計算 (lib/backtest-metrics.sh)。
set -uo pipefail
MRA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$MRA_DIR/lib/backtest-metrics.sh"

errors=0; pass=0
ok()   { echo "PASS: $1"; pass=$((pass+1)); }
fail() { echo "FAIL: $1"; errors=$((errors+1)); }
eq()   { if [[ "$2" == "$3" ]]; then ok "$1"; else fail "$1 — expected [$2] got [$3]"; fi; }

expected='[
 {"path":"app/a.rb","line":95,"severity":"HIGH","note":"回傳值沒判 nil"},
 {"path":"app/b.rb","line":30,"severity":"CRITICAL","note":"少了權限檢查"},
 {"path":"app/c.rb","line":10,"severity":"MEDIUM","note":"命名不一致"}
]'
review='{"status":"CHANGES_REQUESTED","summary":"x","comments":[
 {"path":"app/a.rb","line":97,"body":"nil 沒處理","severity":"HIGH"},
 {"path":"app/b.rb","line":30,"body":"權限","severity":"MEDIUM"},
 {"path":"app/z.rb","line":5,"body":"別的問題","severity":"LOW"}
]}'

m="$(backtest_match "$review" "$expected" 5)"
eq "三筆期望都有結果" "3" "$(printf '%s' "$m" | jq 'length')"
# a.rb:95 與 comment 的 97 相差 2,在容差 5 內 → 命中
eq "容差內命中"   "97"   "$(printf '%s' "$m" | jq -r '.[0].matched.line')"
# b.rb:30 完全相同 → 命中
eq "同行命中"     "30"   "$(printf '%s' "$m" | jq -r '.[1].matched.line')"
# c.rb 沒有任何 comment → 漏抓
eq "無對應為 null" "null" "$(printf '%s' "$m" | jq -r '.[2].matched')"

# 容差縮到 1,a.rb 就不該命中了
m1="$(backtest_match "$review" "$expected" 1)"
eq "容差 1 不命中" "null" "$(printf '%s' "$m1" | jq -r '.[0].matched')"

r="$(backtest_metrics "$m" "$review")"
eq "期望總數"   "3" "$(printf '%s' "$r" | jq -r '.expected_total')"
eq "漏抓數"     "1" "$(printf '%s' "$r" | jq -r '.missed')"
eq "漏抓率"     "0.33" "$(printf '%s' "$r" | jq -r '.miss_rate')"
eq "comment 總數" "3" "$(printf '%s' "$r" | jq -r '.comments_total')"
eq "未對應數"   "1" "$(printf '%s' "$r" | jq -r '.unmatched')"
eq "未對應率"   "0.33" "$(printf '%s' "$r" | jq -r '.unmatched_rate')"
# 兩筆命中,a.rb 的 HIGH 對、b.rb 標 MEDIUM 但期望 CRITICAL 錯
eq "嚴重度吻合" "1" "$(printf '%s' "$r" | jq -r '.severity_agree')"
eq "嚴重度吻合率" "0.5" "$(printf '%s' "$r" | jq -r '.severity_rate')"

# 特殊情況：沒有任何 comment
r0="$(backtest_metrics "$(backtest_match '{"status":"APPROVED","summary":"x","comments":[]}' "$expected" 5)" \
       '{"status":"APPROVED","summary":"x","comments":[]}')"
eq "全漏抓" "1" "$(printf '%s' "$r0" | jq -r '.miss_rate')"
eq "未對應率 0(無分母時為 0)" "0" "$(printf '%s' "$r0" | jq -r '.unmatched_rate')"
eq "嚴重度率 0(無分母時為 0)" "0" "$(printf '%s' "$r0" | jq -r '.severity_rate')"

# 特殊情況：期望為空
re="$(backtest_metrics "$(backtest_match "$review" '[]' 5)" "$review")"
eq "期望為空時漏抓率 0" "0" "$(printf '%s' "$re" | jq -r '.miss_rate')"

echo "---"; echo "Passed: $pass"; echo "Failed: $errors"
exit $((errors > 0 ? 1 : 0))
```

- [ ] **Step 2: 跑測試確認失敗**

Run: `bash tests/test_backtest_metrics.sh`
Expected: FAIL，訊息是 `lib/backtest-metrics.sh: No such file or directory`

- [ ] **Step 3: 寫最小實作**

建立 `lib/backtest-metrics.sh`：

```bash
#!/usr/bin/env bash
# 回測的三個指標。
#
# 命中的定義是「同一個檔案，且行號差在容差內」。用容差是因為 review 指的行與
# 缺陷實際所在的行常差幾行，逐行嚴格比對會把命中判成漏抓。
#
# unmatched_rate 不是誤報率。review 找到基準集沒收錄的真問題也會計入，所以只能
# 用來看新舊規則之間的趨勢，不能當成絕對的誤報數字。

backtest_match() {
  local review="$1" expected="$2" tol="${3:-5}"
  jq -n --argjson review "$review" --argjson expected "$expected" --argjson tol "$tol" '
    [ $expected[] as $e
      | { expected: $e,
          matched: ( [ $review.comments[]
                       | select(.path == $e.path)
                       | select((.line - $e.line) | fabs <= $tol) ]
                     | sort_by((.line - $e.line) | fabs) | .[0] // null ) } ]'
}

backtest_metrics() {
  local matches="$1" review="$2"
  jq -n --argjson m "$matches" --argjson r "$review" '
    ($m | length) as $et
    | ([$m[] | select(.matched == null)] | length) as $missed
    | ([$m[] | select(.matched != null)]) as $hits
    | ($r.comments | length) as $ct
    | ([$hits[].matched.line] | unique) as $hit_lines
    | ([$r.comments[] | select([.line] | inside($hit_lines) | not)] | length) as $unmatched
    | ([$hits[] | select(.matched.severity == .expected.severity)] | length) as $agree
    | def round2: (. * 100 | round) / 100;
      { expected_total: $et,
        missed: $missed,
        miss_rate: (if $et == 0 then 0 else ($missed / $et) | round2 end),
        comments_total: $ct,
        unmatched: $unmatched,
        unmatched_rate: (if $ct == 0 then 0 else ($unmatched / $ct) | round2 end),
        severity_agree: $agree,
        severity_rate: (if ($hits | length) == 0 then 0 else ($agree / ($hits | length)) | round2 end) }'
}
```

- [ ] **Step 4: 跑測試確認通過**

Run: `bash tests/test_backtest_metrics.sh`
Expected: PASS，`Failed: 0`

若 `unmatched` 的算法在多個 comment 指到同一行時算錯，改用 comment 的陣列索引比對，
不要用 line 值比對。測試裡的 `app/z.rb:5` 與命中的 `97`、`30` 不重疊，所以初版用 line
值可以過；真實資料出現同行多 comment 時要換成索引。

- [ ] **Step 5: lint**

Run: `shellcheck -S warning lib/backtest-metrics.sh tests/test_backtest_metrics.sh`
Expected: 無輸出

- [ ] **Step 6: Commit**

```bash
git add lib/backtest-metrics.sh tests/test_backtest_metrics.sh
git commit -m "feat(backtest): 漏抓率、未對應率、嚴重度吻合率"
```

---

### Task 6: 跑出基準線

階段二的驗收。用**現有的** persona 對確認過的基準集跑一輪，把三個指標的數字記下來。
階段四的新規則要跟這組數字比。

**Files:**
- Create: `scripts/run-backtest.sh`
- Create: `docs/superpowers/notes/2026-backtest-baseline.md`
- Test: `tests/test_run_backtest.sh`

**Interfaces:**
- Consumes: Task 4 的 `candidates.json`、Task 5 的 `backtest_match` 與 `backtest_metrics`
- Produces:
  - `scripts/run-backtest.sh --label <名稱> [--tolerance N]` → 對每個 `confirmed == true` 的 PR 跑 `mra review --strategy personas`，輸出存 `<bench>/runs/<label>/<repo>__<pr>.json`，彙總存 `<bench>/runs/<label>/summary.json`
  - `scripts/run-backtest.sh --compare <label_a> <label_b>` → 印出兩組指標的對照表

- [ ] **Step 1: 寫失敗的測試**

建立 `tests/test_run_backtest.sh`。用 PATH shim 假造 `mra`，不真的呼叫 LLM：

```bash
#!/usr/bin/env bash
# 回測執行 (scripts/run-backtest.sh)。假造 mra，不呼叫 LLM。
set -uo pipefail
MRA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export MRA_BENCHMARK_DIR="$TMP/bench"
mkdir -p "$MRA_BENCHMARK_DIR" "$TMP/bin"

cat > "$MRA_BENCHMARK_DIR/candidates.json" <<'J'
[
 {"repo":"acme/rails-app-1","pr":4919,"merged_at":"2026-08-10T09:09:52Z","fix_commits":[],
  "confirmed":true,
  "expected_findings":[{"path":"app/a.rb","line":95,"severity":"HIGH","note":"nil"},
                       {"path":"app/c.rb","line":10,"severity":"MEDIUM","note":"命名"}]},
 {"repo":"acme/rails-app-1","pr":4911,"merged_at":"2026-08-01T00:00:00Z","fix_commits":[],
  "confirmed":false,"expected_findings":[]}
]
J

cat > "$TMP/bin/mra" <<'SHIM'
#!/usr/bin/env bash
# 只回一筆命中 app/a.rb:97 的 comment,app/c.rb 那筆故意漏掉
printf '%s' '{"status":"CHANGES_REQUESTED","summary":"x","comments":[
  {"path":"app/a.rb","line":97,"body":"nil 沒處理","severity":"HIGH"}]}'
SHIM
chmod +x "$TMP/bin/mra"; export PATH="$TMP/bin:$PATH"
export MRA_BACKTEST_CMD="mra"

errors=0; pass=0
ok()   { echo "PASS: $1"; pass=$((pass+1)); }
fail() { echo "FAIL: $1"; errors=$((errors+1)); }
eq()   { if [[ "$2" == "$3" ]]; then ok "$1"; else fail "$1 — expected [$2] got [$3]"; fi; }
S="$MRA_DIR/scripts/run-backtest.sh"

bash "$S" --label baseline >/dev/null 2>&1
eq "退出碼 0" "0" "$?"

R="$TMP/bench/runs/baseline"
if [[ -s "$R/acme__rails-app-1__4919.json" ]]; then ok "跑了 confirmed=true 的 PR"; else fail "沒跑 4919"; fi
if [[ -e "$R/acme__rails-app-1__4911.json" ]]; then fail "不該跑 confirmed=false 的 PR"; else ok "跳過 confirmed=false"; fi

S1="$R/summary.json"
eq "期望總數"     "2"    "$(jq -r '.expected_total' "$S1")"
eq "漏抓 1 筆"    "1"    "$(jq -r '.missed' "$S1")"
eq "漏抓率 0.5"   "0.5"  "$(jq -r '.miss_rate' "$S1")"
eq "嚴重度全對"   "1"    "$(jq -r '.severity_rate' "$S1")"
eq "PR 數"        "1"    "$(jq -r '.prs' "$S1")"

# 對照兩個 label
bash "$S" --label after >/dev/null 2>&1
out="$(bash "$S" --compare baseline after)"
case "$out" in *baseline*after*) ok "對照表含兩個 label" ;; *) fail "對照表不對：$out" ;; esac
case "$out" in *miss_rate*) ok "對照表含 miss_rate" ;; *) fail "缺 miss_rate" ;; esac

# 沒有任何 confirmed=true 時要明講,不要輸出空的 summary 假裝跑過
jq 'map(.confirmed = false)' "$MRA_BENCHMARK_DIR/candidates.json" > "$TMP/c.json"
mv "$TMP/c.json" "$MRA_BENCHMARK_DIR/candidates.json"
if bash "$S" --label empty >/dev/null 2>&1; then fail "無基準時應退出非 0"; else ok "無基準時退出非 0"; fi

echo "---"; echo "Passed: $pass"; echo "Failed: $errors"
exit $((errors > 0 ? 1 : 0))
```

- [ ] **Step 2: 跑測試確認失敗**

Run: `bash tests/test_run_backtest.sh`
Expected: FAIL，訊息是 `scripts/run-backtest.sh: No such file or directory`

- [ ] **Step 3: 寫最小實作**

建立 `scripts/run-backtest.sh`：

```bash
#!/usr/bin/env bash
# 對基準集跑一輪 review 並算出三個指標。
#
# 不 post 到 PR。每個 PR 的 review 輸出各存一個檔，彙總存 summary.json，
# 讓新舊規則可以用 --compare 直接比。
#
# 沒有任何 confirmed==true 的基準時直接退出非 0。輸出一份 0 筆的 summary 會讓人
# 以為跑過了，那正是 2026-06-23 false-green 的形狀。
set -uo pipefail

MRA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$MRA_DIR/lib/backtest-metrics.sh"

BENCH_DIR="${MRA_BENCHMARK_DIR:-$HOME/.cache/mra-review-benchmark}"
C="$BENCH_DIR/candidates.json"
MRA_CMD="${MRA_BACKTEST_CMD:-$MRA_DIR/bin/mra.sh}"

LABEL=""; TOL=5
case "${1:-}" in
  --compare)
    a="$BENCH_DIR/runs/$2/summary.json"; b="$BENCH_DIR/runs/$3/summary.json"
    for f in "$a" "$b"; do [[ -f "$f" ]] || { echo "找不到 $f" >&2; exit 1; }; done
    printf '%-18s %10s %10s\n' "指標" "$2" "$3"
    for k in expected_total missed miss_rate comments_total unmatched unmatched_rate severity_agree severity_rate; do
      printf '%-18s %10s %10s\n' "$k" "$(jq -r ".$k" "$a")" "$(jq -r ".$k" "$b")"
    done
    exit 0 ;;
esac

while [[ $# -gt 0 ]]; do
  case "$1" in
    --label)     LABEL="$2"; shift 2 ;;
    --tolerance) TOL="$2"; shift 2 ;;
    -h|--help)
      echo "用法: run-backtest.sh --label <名稱> [--tolerance N] | --compare <a> <b>"
      exit 0 ;;
    *) echo "未知參數：$1" >&2; exit 1 ;;
  esac
done
[[ -z "$LABEL" ]] && { echo "缺 --label" >&2; exit 1; }
[[ -f "$C" ]] || { echo "找不到 $C" >&2; exit 1; }

n_conf="$(jq '[.[] | select(.confirmed == true)] | length' "$C")"
if [[ "$n_conf" -eq 0 ]]; then
  echo "基準集裡沒有 confirmed==true 的 PR，先跑 scripts/review-benchmark.sh 完成人工確認" >&2
  exit 1
fi

OUT="$BENCH_DIR/runs/$LABEL"
mkdir -p "$OUT"

all_matches='[]'; all_comments='[]'; prs=0
for ((i = 0; i < n_conf; i++)); do
  item="$(jq -c "[.[] | select(.confirmed == true)] | .[$i]" "$C")"
  repo="$(printf '%s' "$item" | jq -r '.repo')"
  pr="$(printf '%s' "$item" | jq -r '.pr')"
  expected="$(printf '%s' "$item" | jq -c '.expected_findings')"

  f="$OUT/$(printf '%s' "$repo" | tr '/' '_')__${pr}.json"
  if [[ ! -s "$f" ]]; then
    "$MRA_CMD" review "$repo" --pr "$pr" --strategy personas --json > "$f" 2>/dev/null || {
      echo "review 失敗：$repo#$pr" >&2; rm -f "$f"; continue; }
  fi
  jq -e '.comments' "$f" >/dev/null 2>&1 || { echo "輸出格式不符：$f" >&2; continue; }

  review="$(cat "$f")"
  m="$(backtest_match "$review" "$expected" "$TOL")"
  all_matches="$(jq -n --argjson a "$all_matches" --argjson b "$m" '$a + $b')"
  all_comments="$(jq -n --argjson a "$all_comments" --argjson r "$review" '$a + $r.comments')"
  prs=$((prs + 1))
done

summary="$(backtest_metrics "$all_matches" "$(jq -n --argjson c "$all_comments" \
  '{status: "COMMENT", summary: "aggregate", comments: $c}')")"
printf '%s' "$summary" | jq --argjson prs "$prs" --arg label "$LABEL" \
  '. + {prs: $prs, label: $label}' > "$OUT/summary.json"

echo "label=$LABEL prs=$prs"
jq -r '"漏抓率 \(.miss_rate)  未對應率 \(.unmatched_rate)  嚴重度吻合率 \(.severity_rate)"' "$OUT/summary.json"
```

- [ ] **Step 4: 跑測試確認通過**

Run: `bash tests/test_run_backtest.sh`
Expected: PASS，`Failed: 0`

- [ ] **Step 5: 跑全套測試**

Run: `make test`
Expected: 全數通過

- [ ] **Step 6: lint**

Run: `shellcheck -S warning scripts/run-backtest.sh tests/test_run_backtest.sh`
Expected: 無輸出

- [ ] **Step 7: 對真實資料建基準集**

```bash
gh auth switch --user acme-bot
for r in acme/rails-app-1 acme/nest-monorepo-2.0 acme/react-app-1 acme/nest-app-2; do
  bash scripts/build-benchmark.sh --repo "$r" --limit 100
done
bash scripts/review-benchmark.sh --status
```

Expected: 候選約 100 到 140 筆（依 12.5% 命中率推算）。

- [ ] **Step 8: 人工確認到 30 到 40 筆**

反覆執行，直到 `--status` 顯示確認為缺陷達 30 筆以上：

```bash
bash scripts/review-benchmark.sh --next
# 看完之後
bash scripts/review-benchmark.sh --set <pr> true
bash scripts/review-benchmark.sh --add <pr> <path> <line> <severity> <當初該抓到什麼>
```

判斷標準：那個 fix commit 是在修這個 PR 引入的問題，才算 `true`。同一個檔案剛好又被
改到、或修的是這個 PR 之前就存在的問題，都算 `false`。

- [ ] **Step 9: 跑基準線**

```bash
bash scripts/run-backtest.sh --label baseline
gh auth switch --user hanfour
```

Expected: 印出三個指標。這一輪會對 30 到 40 個真實 PR 各跑一次 5 persona 的 review，
時間與 token 成本都不低，跑之前確認額度足夠。

- [ ] **Step 10: 記錄並 commit**

把 `summary.json` 的內容與每個 PR 的漏抓情形寫進
`docs/superpowers/notes/2026-backtest-baseline.md`，並把 `candidates.json` 複製一份到
`tests/fixtures/backtest/benchmark-sample.json`（去掉內部路徑與人名）。

```bash
git add docs/superpowers/notes/2026-backtest-baseline.md tests/fixtures/backtest/benchmark-sample.json
git commit -m "docs(backtest): 記錄現有 persona 的基準線指標"
```

階段二到此結束。有了這組數字，階段三的規則萃取才有東西可以驗證。
