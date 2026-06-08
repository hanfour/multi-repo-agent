# 指令總覽

mra 提供 32 個指令，依用途分組。

## 跨 Repo 開發

| 指令 | 用途 |
|------|------|
| `mra <project...> [--with-deps]` | 啟動 Claude orchestrator，載入指定專案 |
| `mra --all` | 載入工作區所有專案 |
| `mra ask <project> "<question>"` | 單次 codebase 查詢 |

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
| `mra review <project>` | 在終端機輸出 review |
| `mra review <project> --pr N` | 在 GitHub PR 留 inline comments |
| `mra review <project> --personas` | 跑 5 位具名領域專家 |
| `mra plan <project> "<task>"` | 多專家實作計畫（`--dual`：claude + codex）|
| `mra test-audit <project>` | Kent Beck 11 原則測試稽核 |

## 知識與 Context

| 指令 | 用途 |
|------|------|
| `mra analyze <project>` | 產生 Project Knowledge Base |
| `mra export <project>` | 輸出專案 context 檔案 |

## 測試與 Docker

| 指令 | 用途 |
|------|------|
| `mra db setup` | 啟動 DB 容器並匯入 dump |
| `mra test <project>` | 跑測試（自動判斷策略）|
| `mra watch <project>` | 檔案變更時自動跑測試 |

完整指令列表請見 [README](https://github.com/hanfour/multi-repo-agent#command-reference)。
