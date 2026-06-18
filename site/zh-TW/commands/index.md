# 指令總覽

mra 提供 32 個指令，依用途分組。

## 跨 Repo 開發

| 指令 | 用途 |
|------|------|
| `mra <project...> [--with-deps]` | 啟動 Claude orchestrator，載入指定專案 |
| `mra --all` | 載入工作區所有專案 |
| [`mra ask <project> "<question>"`](/zh-TW/commands/ops) | 單次 codebase 查詢 |

## 工作區與依賴圖

| 指令 | 用途 |
|------|------|
| [`mra init <path> --git-org <url>`](/zh-TW/commands/workspace) | 初始化工作區 |
| [`mra scan [path]`](/zh-TW/commands/workspace) | 重新掃描依賴 |
| [`mra deps [project]`](/zh-TW/commands/workspace) | 顯示依賴圖 |
| [`mra graph [--mermaid\|--dot]`](/zh-TW/commands/workspace) | 視覺化依賴圖 |
| [`alias`](/zh-TW/commands/workspace) · [`config`](/zh-TW/commands/workspace) · [`setup`](/zh-TW/commands/workspace) · [`template`](/zh-TW/commands/workspace) · [`open`](/zh-TW/commands/workspace) · [`doctor`](/zh-TW/commands/workspace) · [`clean`](/zh-TW/commands/workspace) | 建置、導覽與維護 |

## 分支與同步

| 指令 | 用途 |
|------|------|
| [`mra sync`](/zh-TW/commands/sync) | clone/pull 每個 repo（`--safe`/`--push`/`--review`/`--json`）|
| [`mra branch status`](/zh-TW/commands/branch) | 跨 repo 分支總覽（`--all`/`--fetch`/`--json`）|
| [`mra branch new\|switch <name>`](/zh-TW/commands/branch) | 跨 repo 建立/切換同一條分支 |
| [`mra branch pr [repos…]`](/zh-TW/commands/branch) | push 分支並開 PR（相依先）|
| [`mra branch merge [repos…]`](/zh-TW/commands/branch) | 合併 PR，以 mergeable + CI 為門檻（`--wait-ci`）|

## Code Review

| 指令 | 用途 |
|------|------|
| [`mra review <project>`](/zh-TW/commands/review) | 在終端機輸出 review |
| `mra review <project> --pr N` | 在 GitHub PR 留 inline comments |
| `mra review <project> --personas` | 跑 5 位具名領域專家 |
| [`mra plan <project> "<task>"`](/zh-TW/commands/plan) | 多專家實作計畫（`--dual`：claude + codex）|
| [`mra test-audit <project>`](/zh-TW/commands/test-audit) | Kent Beck 11 原則測試稽核 |
| [`mra eval-review <project> --pr N`](/zh-TW/commands/ops) | 以人工 baseline 評分 AI review |

## 知識與 Context

| 指令 | 用途 |
|------|------|
| [`mra analyze <project>`](/zh-TW/commands/pkb) | 產生 Project Knowledge Base |
| [`mra export <project>`](/zh-TW/commands/ops) | 輸出專案 context 檔案 |

## 測試與 Docker

| 指令 | 用途 |
|------|------|
| [`mra trust <project>`](/zh-TW/commands/testing) | 授權 Docker（每專案一次）|
| [`mra db [setup\|status\|import]`](/zh-TW/commands/testing) | 啟動 DB 容器並匯入 dump |
| [`mra test <project>`](/zh-TW/commands/testing) | 跑測試（自動判斷策略）|
| [`mra watch <project>`](/zh-TW/commands/testing) | 檔案變更時自動跑測試 |

## 快照與回滾

| 指令 | 用途 |
|------|------|
| [`mra snapshot [name]`](/zh-TW/commands/snapshots) · [`snapshots`](/zh-TW/commands/snapshots) | 擷取 / 列出狀態快照 |
| [`mra rollback <project> [name]`](/zh-TW/commands/snapshots) | 還原到快照（摧毀前先詢問）|

## 狀態與維運

| 指令 | 用途 |
|------|------|
| [`mra status`](/zh-TW/commands/ops) · [`log`](/zh-TW/commands/ops) · [`diff`](/zh-TW/commands/ops) · [`cost`](/zh-TW/commands/ops) · [`dashboard`](/zh-TW/commands/ops) | 觀察工作區 |
| [`mra lint <project\|--all>`](/zh-TW/commands/ops) | 檢查 JS/TS BLOCKER 規則 |
| [`mra ci <project>`](/zh-TW/commands/ops) | 產生 GitHub Actions workflow |
| [`mra notify`](/zh-TW/commands/ops) · [`federation`](/zh-TW/commands/ops) | 通知與多工作區契約 |

完整指令列表請見 [README](https://github.com/hanfour/multi-repo-agent#command-reference)。
