# persona 慣例比對與覆蓋清單 實作計畫

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在 `mra review --strategy personas` 加一個「慣例比對」persona，並讓既有 5 個 persona 共用的 prompt 樣板多一道「覆蓋清單」要求，處理兩個已用真實案例證實的 file_miss 成因。

**Architecture:** `agents/personas/` 底下新增一個 `.md` persona 檔（`lib/personas.sh` 自動掃描），`lib/review-personas.sh` 的 `default_review_personas()` 把它加進預設清單；`build_persona_prompt()` 的共用樣板加一段覆蓋清單指示。兩者都不動 `run_persona_review`／`run_synthesize` 的控制流程，只動內容。

**Tech Stack:** bash（與既有 personas/review 程式碼一致）

**Spec:** `docs/superpowers/specs/2026-08-26-persona-convention-coverage-design.md`

## Global Constraints

- 新 persona 檔案必須帶 `FOCUS:` 錨點（`lib/rule-schema.sh`／`lib/rule-inject.sh` 靠這個判斷能不能注入規則），否則會被規則注入誤判成第二個「無法注入」的 persona
- 新 persona 檔案上限 3KB（`agents/personas/README.md` 既定慣例）
- 驗證用的回測必須用 `candidates_sha` = `7a8226ee333100a9` 的候選集，跟階段二、階段三的基準線一致
- 這次改動不動 synthesize 輪數、debate 策略路徑、規則注入邏輯本身

---

## 檔案結構

| 檔案 | 責任 |
| --- | --- |
| `agents/personas/convention-auditor.md` | 新 persona：對照 codebase 既有慣例 |
| `lib/review-personas.sh` | `default_review_personas()` 加入新 persona；`build_persona_prompt()` 加覆蓋清單要求 |
| `tests/test_personas.sh` | 既有測試，加入對新 persona 的檢查 |
| `tests/test_review_personas.sh` | 既有測試，加入對新 persona 與覆蓋清單要求的檢查 |
| `tests/test_rule_inject.sh` | 既有測試，persona 計數斷言從 5 改成 6 |
| `tests/test_run_rule_backtest.sh` | 既有測試，persona 計數與比例斷言從 4/5 改成 5/6 |

---

### Task 1: 新增 convention-auditor persona

兩個已追蹤的案例（見 spec）都證實 file_miss 的其中一種成因是「persona 讀過
檔案、做出具體判斷，但沒有人的判準涵蓋跟既有慣例比對」。新增一個專門負責
這件事的 persona，跟既有 5 個一樣平行跑。

**Files:**
- Create: `agents/personas/convention-auditor.md`
- Modify: `lib/review-personas.sh:5-7`（`default_review_personas`）
- Modify: `tests/test_personas.sh`
- Modify: `tests/test_review_personas.sh`
- Modify: `tests/test_rule_inject.sh:14,490,646`
- Modify: `tests/test_run_rule_backtest.sh:12-15,175,371,378-380`

**Interfaces:**
- Consumes: `lib/personas.sh` 的 `load_persona`／`list_personas`（自動掃描
  `agents/personas/*.md`，不用額外註冊）
- Produces: `default_review_personas()` 回傳的字串多一個 token
  `convention-auditor`，供 `lib/review.sh:428` 與 `lib/rule-inject.sh` 的
  `rule_inject_all`／`rule_inject_layers` 使用

- [ ] **Step 1: 寫失敗的測試**

在 `tests/test_personas.sh` 的迴圈清單加入新 persona：

```bash
# tests/test_personas.sh — 把迴圈清單改成
for p in security-auditor api-contract-guardian performance-hawk refactoring-sage test-architect convention-auditor; do
```

在 `tests/test_review_personas.sh` 的迴圈清單加入新 persona：

```bash
# tests/test_review_personas.sh — 把迴圈清單改成
for p in security-auditor api-contract-guardian performance-hawk refactoring-sage test-architect convention-auditor; do
```

- [ ] **Step 2: 跑測試確認失敗**

Run: `bash tests/test_personas.sh && bash tests/test_review_personas.sh`
Expected: FAIL，`persona convention-auditor did not load` 或
`default set missing convention-auditor`

- [ ] **Step 3: 建立 convention-auditor.md**

```markdown
ROLE: Convention Auditor
STYLE: 資深維護者 — 不問「這樣寫對不對」，問「跟旁邊那份比一致嗎」。

FOCUS:
- 新增/修改的函式跟同目錄或同 feature 裡同類型的其他檔案（同樣是 query、
  mutation、hook、middleware……）比，行為模式是否一致
- 錯誤處理、loading/empty state、權限守門的慣例是否跟 sibling 程式碼一樣
- 有沒有本該套用某個既有 helper／wrapper 卻手刻一份
- 命名以外的行為慣例（helper 呼叫順序、flag 預設值、錯誤吞不吞）

SCOPE NOTE: 不管命名／結構整潔（那是 refactoring-sage 的事），只管「這裡
跟別處的實際行為是否一致」。

METHOD:
1. 對每個改動的檔案，判斷它屬於哪一種角色（query/mutation/hook/component…）。
2. 用 Grep 找同角色的其他檔案（同目錄或同 feature 家族）。
3. 逐項比對行為慣例，只在真的找到至少一個 sibling 可比對時才報。找不到
   sibling 就略過，不要用「應該要」的臆測取代真的比對過的證據。

OUTPUT FORMAT:
- [HIGH] `file:line` — <跟哪個 sibling file:line 比對出的不一致>
- [MEDIUM] `file:line` — <輕微的行為慣例落差>
```

- [ ] **Step 4: 註冊進 default_review_personas**

```bash
# lib/review-personas.sh:5-7，改成
default_review_personas() {
  echo "security-auditor api-contract-guardian performance-hawk refactoring-sage test-architect convention-auditor"
}
```

- [ ] **Step 5: 跑測試確認通過**

Run: `bash tests/test_personas.sh && bash tests/test_review_personas.sh`
Expected: PASS

- [ ] **Step 6: 跑全套測試，找出因為 persona 從 5 個變 6 個而連帶失敗的既有測試**

Run: `bash test.sh` （或專案既有的完整測試入口）
Expected: `tests/test_rule_inject.sh` 與 `tests/test_run_rule_backtest.sh` 失敗，
因為兩者對真實 `agents/personas/` 目錄底下的 persona 數量寫死了 `5`

- [ ] **Step 7: 修正 test_rule_inject.sh 的計數斷言**

```bash
# tests/test_rule_inject.sh:14，註解從
#   2. 五個 persona 都被處理到（含完全沒有 FOCUS 的 test-architect.md）。
# 改成
#   2. 六個 persona 都被處理到（含完全沒有 FOCUS 的 test-architect.md）。

# tests/test_rule_inject.sh:490，改成
  eq "處理了 agents/personas 底下 6 個 persona（不含 README）" "6" "$n"

# tests/test_rule_inject.sh:646，改成
  eq "第二欄是 persona 總數" "6" "$(printf '%s' "$report" | cut -f2)"
```

- [ ] **Step 8: 修正 test_run_rule_backtest.sh 的計數與比例斷言**

```bash
# tests/test_run_rule_backtest.sh:12-15，註解從
#   2. brief 原本完全沒有任何地方回報「幾個 persona 真的拿到規則」，而
#      agents/personas/test-architect.md 沒有 FOCUS 錨點是這個專案已知、
#      刻意不修的事實（修了會讓基準線 C 不可比）——這裡驗證訊息確實印出
#      「4/5」，並且寫進執行條件記錄裡，不是只印在 stdout 上跑完就沒了。
# 改成
#   2. brief 原本完全沒有任何地方回報「幾個 persona 真的拿到規則」，而
#      agents/personas/test-architect.md 沒有 FOCUS 錨點是這個專案已知、
#      刻意不修的事實（修了會讓基準線 C 不可比）——這裡驗證訊息確實印出
#      「5/6」，並且寫進執行條件記錄裡，不是只印在 stdout 上跑完就沒了。

# tests/test_run_rule_backtest.sh:175，改成
  eq "每層的 persona 總數仍是 6" "6" \
    "$(jq -r '.layers[] | select(.layer == "rails") | .persona_total' "$cond")"

# tests/test_run_rule_backtest.sh:371，改成
  has "印出注入比例 5/6" "$out" "注入 5/6 個 persona"

# tests/test_run_rule_backtest.sh:378-380，改成
  eq "persona_total 記成 6" "6" "$(jq -r '.persona_total' "$cond")"
  eq "persona_injected 記成 5" "5" "$(jq -r '.persona_injected' "$cond")"
  eq "persona_skipped 記成 1" "1" "$(jq -r '.persona_skipped' "$cond")"
```

`persona_skipped`／`persona_skipped_names` 維持不變：convention-auditor.md
帶了 `FOCUS:` 錨點，唯一沒有的仍然只有 `test-architect.md`。

- [ ] **Step 9: 跑全套測試確認通過**

Run: `bash test.sh`
Expected: PASS，全數通過

- [ ] **Step 10: Commit**

```bash
git add agents/personas/convention-auditor.md lib/review-personas.sh \
        tests/test_personas.sh tests/test_review_personas.sh \
        tests/test_rule_inject.sh tests/test_run_rule_backtest.sh
git commit -m "feat(review): 新增 convention-auditor persona

兩個追蹤過的 file_miss 案例（PR#764、PR#746）之一：persona 讀過檔案、做出
具體判斷，但沒有人的判準涵蓋跟既有慣例比對。新增專門負責這件事的 persona，
跟既有 5 個一樣平行跑，不拉長總時間。

連帶更新 test_rule_inject.sh／test_run_rule_backtest.sh 裡對真實
agents/personas/ 目錄寫死的 persona 數量斷言（5→6、4/5→5/6）。"
```

---

### Task 2: 共用 prompt 樣板加覆蓋清單要求

另一個已追蹤的成因：同一個 PR 裡有更大、更「有戲」的改動時，小改動的檔案
會被整個略過，連「看過但沒問題」都沒交代。在所有 persona 共用的樣板加一道
要求，逼每個 persona 對 Changed Files 清單裡的每一個檔案都交代結果。

**Files:**
- Modify: `lib/review-personas.sh:26-52`（`build_persona_prompt` 的
  `template`）
- Modify: `tests/test_review_personas.sh`

**Interfaces:**
- Consumes: 無新增（沿用 `build_persona_prompt` 既有的
  `%CHANGED_FILES%` 佔位符）
- Produces: `build_persona_prompt` 回傳的 prompt 文字多一段固定的覆蓋清單
  指示，所有呼叫端（`run_persona_review`）自動拿到，不用改呼叫端

- [ ] **Step 1: 寫失敗的測試**

在 `tests/test_review_personas.sh` 加一個新斷言（跟在既有的
`prompt_lang` 那組測試後面）：

```bash
# tests/test_review_personas.sh — 加在既有測試之後
prompt_coverage=$(build_persona_prompt "security-auditor" "d" "x.js
y.js")
if [[ "$prompt_coverage" != *"把上面 Changed Files 清單裡的每一個檔案都列出來"* ]]; then
  echo "FAIL: prompt missing coverage checklist requirement"; errors=$((errors+1))
fi
```

- [ ] **Step 2: 跑測試確認失敗**

Run: `bash tests/test_review_personas.sh`
Expected: FAIL，`FAIL: prompt missing coverage checklist requirement`

- [ ] **Step 3: 在樣板加覆蓋清單要求**

```bash
# lib/review-personas.sh:26-52，template 改成
  template=$(cat <<'TEMPLATE'
%PERSONA_BODY%

%PKB_SECTION%%CONSUMER_SECTION%

## Diff
```diff
%DIFF%
```

## Changed Files
%CHANGED_FILES%

## 覆蓋確認
結束前，把上面 Changed Files 清單裡的每一個檔案都列出來，各自標 PASS
（看過、沒問題）或列出你的 finding。不能悄悄跳過任何一個檔案。

%LANG%

IMPORTANT: Every finding MUST include exact file:line evidence from the source.
TEMPLATE
)
```

（只在 `## Changed Files` 區塊後面、`%LANG%` 之前插入新的 `## 覆蓋確認`
段落，其餘樣板內容不變。）

- [ ] **Step 4: 跑測試確認通過**

Run: `bash tests/test_review_personas.sh`
Expected: PASS

- [ ] **Step 5: 跑全套測試確認沒有連帶影響**

Run: `bash test.sh`
Expected: PASS。這一步不預期任何既有測試因為樣板變動而失敗——樣板變動只
是在既有段落之間插入新文字，沒有改動任何既有佔位符的位置或格式。

- [ ] **Step 6: Commit**

```bash
git add lib/review-personas.sh tests/test_review_personas.sh
git commit -m "feat(review): persona prompt 加覆蓋清單要求

另一個追蹤過的 file_miss 案例（PR#746）：同一個 PR 裡有更大的改動時，小
改動的檔案被整個略過，連「看過但沒問題」都沒交代。要求每個 persona 結束前
把 Changed Files 清單逐一交代，用很輕的成本換一個不會被靜默略過的下限。"
```

---

### Task 3: 驗證——重跑基準線比對 file_miss_rate

這不是單元測試能驗的東西，要用真實回測看數字有沒有動。

**注意執行條件（前兩個任務執行時已經踩過的坑，這裡先記下來）：**
- `MRA_BACKTEST_WORKSPACE` 要指到 repo 實際 checkout 的位置（不是預設的
  `~/workspace`）
- `gh` 的 active 帳號可能不是 review 目標 repo 需要的帳號，`GH_TOKEN` 要
  明確指定：`GH_TOKEN="$(gh auth token --user <正確帳號>)"`
- 完整跑一輪 38 個 PR 要幾小時、相當量的 API 額度，且這個 harness 環境曾經
  出現背景任務被中止（非使用者主動中斷）的狀況——長時間執行建議用
  `nohup ... & disown` 讓行程脫離工具追蹤的行程樹，並把進度寫進可以事後
  查詢的 log 檔，而不是完全依賴工具的完成通知

**Files:** 無程式碼異動，只跑既有的 `scripts/run-backtest.sh`

- [ ] **Step 1: 單獨重跑 PR#764，確認 convention-auditor 抓到 skipGlobalError 缺漏**

```bash
GH_TOKEN="$(gh auth token --user acme-bot)" \
MRA_BACKTEST_WORKSPACE="$HOME/workspace" \
MRA_BACKTEST_REVIEW_MODE=personas \
MRA_REVIEW_PERSONA_MAX_TURNS=20 \
  bash scripts/backtest-review-adapter.sh review acme/nest-monorepo-2.0 --pr 764 \
    --strategy personas --json > /tmp/pr764-after.json
jq -c '.comments[] | select(.path == "apps/frontend/src/features/audience-targeting/queries/device-type-options.ts")' \
  /tmp/pr764-after.json
```

Expected: 至少一條 comment 落在 `device-type-options.ts`，內容跟
`skipGlobalError` 或錯誤處理重複有關。不保證命中——這是一次觀察，不是
迴歸測試——但如果完全沒有任何 comment 落在這個檔案，代表新 persona 的
FOCUS 寫法需要調整，回頭修 Task 1 的 persona 內容再重跑這一步。

- [ ] **Step 2: 單獨重跑 PR#746，確認覆蓋清單要求讓 $lineItemId.tsx 被交代**

```bash
GH_TOKEN="$(gh auth token --user acme-bot)" \
MRA_BACKTEST_WORKSPACE="$HOME/workspace" \
MRA_BACKTEST_REVIEW_MODE=personas \
MRA_REVIEW_PERSONA_MAX_TURNS=20 \
  bash scripts/backtest-review-adapter.sh review acme/nest-monorepo-2.0 --pr 746 \
    --strategy personas --json > /tmp/pr746-after.json
jq -c '.comments[] | select(.path | contains("lineItemId"))' /tmp/pr746-after.json
```

Expected: 同樣是觀察性檢查，不強制要求命中；但如果連「被提到」都沒有，
表示覆蓋清單要求在 synthesize 階段被稀釋掉了，需要回頭檢查
`run_synthesize` 有沒有保留住這個要求（這次計畫沒有動 synthesize，如果
真的被稀釋掉，屬於下一輪要處理的範圍，不在這次計畫內硬修）。

- [ ] **Step 3: 跑完整 38 個 PR 的 personas 基準線（不帶規則注入）**

```bash
GH_TOKEN="$(gh auth token --user acme-bot)" \
MRA_BACKTEST_CMD="$(pwd)/scripts/backtest-review-adapter.sh" \
MRA_BACKTEST_REVIEW_MODE=personas \
MRA_REVIEW_PERSONA_MAX_TURNS=20 \
MRA_BACKTEST_WORKSPACE="$HOME/workspace" \
  nohup bash scripts/run-backtest.sh --label personas-with-convention-auditor \
    --tolerance 15 > /tmp/personas-with-convention-auditor.log 2>&1 &
disown
```

Expected: label `personas-with-convention-auditor` 底下產生跟
`baseline-personas` 同樣形狀的 38 個 PR 輸出與 `summary.json`。

- [ ] **Step 4: 比較 file_miss_rate**

```bash
jq '{miss_rate, file_miss_rate, comments_total, unmatched_rate}' \
  "$HOME/.cache/mra-review-benchmark/runs/baseline-personas/summary-tol15.json"
jq '{miss_rate, file_miss_rate, comments_total, unmatched_rate}' \
  "$HOME/.cache/mra-review-benchmark/runs/personas-with-convention-auditor/summary.json"
```

Expected: `file_miss_rate` 從 baseline-personas 的水準往下動。
`comments_total` 預期上升；同時檢查 `unmatched_rate` 有沒有跟著大幅上漲——
如果新增的 comment 大部分落進 unmatched，代表覆蓋清單要求換來的是雜訊而
不是真的抓到更多缺陷，這個結論要寫進筆記，不要略過不提。

- [ ] **Step 5: 把結果寫進筆記**

把 Step 1、2、4 的結果整理進
`docs/superpowers/notes/2026-persona-convention-coverage.md`（新檔案），
格式比照 `docs/superpowers/notes/2026-layered-injection.md`：執行條件、
整體指標、逐條配對（如果數字動得夠多值得算）、結論、下一步。

---

## 執行順序與相依

Task 1 與 Task 2 互相獨立，可以任何順序做，但都要在 Task 3 之前完成——
Task 3 驗證的是兩者合起來的效果。Task 3 的 Step 1／2 可以在 Task 1、2 各自
完成後立刻各跑一次（快速的單 PR 檢查），Step 3 起的完整基準線要等兩個
Task 都 commit 之後才跑一次就好，不用每個 Task 都各跑一輪 38 個 PR。

## 這個計畫刻意不做的事

- 不改 synthesize 階段的邏輯或輪數
- 不對 debate 策略（Agent A/B）路徑做同樣的改動
- 不加自動化機制驗證覆蓋清單要求真的被 persona 完整遵守（例如比對輸出是否
  窮舉了 Changed Files）——仰賴 Task 3 的回測結果跟人工抽查
