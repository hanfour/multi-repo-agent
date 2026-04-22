<p align="center">
  <h1 align="center">multi-repo-agent (mra)</h1>
  <p align="center">
    <strong>AI 驅動的多倉庫開發 — 只需一個終端機。</strong>
  </p>
  <p align="center">
    <a href="../README.md">English</a> |
    **繁體中文** |
    <a href="./README.ja.md">日本語</a> |
    <a href="./README.ko.md">한국어</a>
  </p>
</p>

---

> 在 repo A 修改一個 API。mra 自動找到 repos B、C、D 中所有的下游使用者 — 檢視影響範圍、更新程式碼，並建立 PR。全部只需一個指令。

**v2.2.0** | 31 個 CLI 指令 | 6 個 AI 代理 | 9 個 MCP 工具 | 24 個測試套件

---

## 為什麼選擇 mra？

現代軟體分散在多個倉庫中。一個 API 的變更可能悄悄地破壞三個前端。Claude Code 一次只能看到一個目錄。

**mra 彌補了這個落差。**

| 沒有 mra | 使用 mra |
|---|---|
| 手動檢查哪些倉庫使用你的 API | `mra scan` 自動偵測跨倉庫的相依性 |
| 每個倉庫分別開啟獨立的 Claude 對話 | `mra my-api --with-deps` 載入所有相關倉庫 |
| 期望審查者能發現破壞性變更 | `mra review --pr 123` 找到 `consumer:42` 仍然參照舊欄位 |
| 每次對話都要重新解釋專案背景 | PKB 快取專案知識 — 代理只需約 50 個 token 即可喚醒 |
| 猜測你的審查品質如何 | `mra eval-review` 對比人工審查計算精確度/召回率 |

---

## 快速開始

```bash
# 安裝
git clone https://github.com/hanfour/multi-repo-agent.git ~/multi-repo-agent
cd ~/multi-repo-agent && bash install.sh && source ~/.zshrc

# 初始化工作區
mra init ~/workspace --git-org git@github.com:my-org

# 驗證設定
mra doctor

# 開始跨倉庫開發
mra my-api --with-deps
```

---

## 核心功能

### 1. 跨倉庫協調

啟動 Claude 並完整載入多個倉庫及其相依性。

```bash
mra my-api --with-deps       # 載入 my-api + 所有使用者/相依套件
mra my-api frontend-app      # 同時載入指定倉庫
mra --all                    # 載入全部
```

協調器會為每個倉庫派遣子代理、依相依順序協調變更，並在每次提交後執行程式碼審查。

### 2. AI 程式碼審查（辯論模式）

根據差異大小自動選擇三種審查策略：

| 策略 | 適用時機 | 方式 |
|----------|------|-----|
| **輕量 (Light)** | <50 行，≤3 個檔案 | 單次掃描，2 輪（約 15 秒） |
| **標準 (Standard)** | <300 行 | 單次掃描，3 輪（約 30 秒） |
| **辯論 (Debate)** | 大型差異或 API 變更 | 2 個分析師 + 投票 + 綜合（約 3 分鐘） |

```bash
mra review my-api              # 終端機輸出（自動選擇策略）
mra review my-api --pr 123     # 在 GitHub PR 上發表行內評論
mra review my-api --strategy debate  # 強制使用完整審查
```

**辯論模式**使用對抗式多代理審查：

```
第 1 輪：兩個代理各自獨立搜尋程式碼庫
  代理 A（影響分析）→ 破損的參照、廢棄程式碼、API 中斷
  代理 B（品質稽核）→ 安全性、模式、型別安全

第 2 輪：信箱投票
  所有發現合併 → 每個代理以證據投票 保留/捨棄
  → 只有有證據支持的發現才會保留

最終：綜合器產生結構化的行內審查
```

所有審查代理都是**唯讀模式**（`--disallowedTools "Write,Edit"`）— 只能讀取。

### 2b. Persona 模式 Review（可選）

當一般的「影響分析 / 品質稽核」分工不足以應付特定 PR 時，可改以五位具名領域專家平行審查：

```bash
mra review my-api --personas          # 啟用 5 位具名領域專家
mra review my-api --pr 123 --personas # 帶 personas 的 PR 審查
```

| Persona | 聚焦領域 |
|---------|-------|
| `security-auditor` | 機密外洩、注入、身份驗證、反序列化（Troy Hunt 風格） |
| `api-contract-guardian` | 跨倉庫簽章漂移、回應結構變更 |
| `performance-hawk` | N+1 查詢、熱路徑 I/O、bundle 膨脹（Vercel 風格） |
| `refactoring-sage` | 程式碼異味、命名、內聚（Martin Fowler 風格） |
| `test-architect` | Kent Beck 的 11 條測試原則 |

每個 persona 都有聚焦的檢視角度，且共用相同的嚴重度階層（CRITICAL/HIGH/MEDIUM）。所有發現會被合併並綜合為與辯論模式相同的 JSON — PR 行內評論行為一致。

若要新增自訂 persona，只需在 `agents/personas/` 下放入一個 markdown 檔案。詳見 `agents/personas/README.md`。

### 3. 專案知識庫 (PKB)

無需每次對話都重新讀取整個程式碼庫，PKB 將專案知識萃取為可重複使用的文件。

```bash
mra analyze my-api    # 一次性：4 個代理平行掃描專案
```

產生內容：

| 文件 | 內容 |
|----------|---------|
| `identity.md` | 專案名稱、類型、一句話描述（約 50 個 token） |
| `sitemap.md` | 檔案樹 + 模組用途索引 |
| `architecture.md` | 架構模式、資料流、技術棧 |
| `conventions.md` | 程式碼風格，含 `[CONVENTION]`/`[PATTERN]`/`[DECISION]` 標籤 |
| `api-surface.md` | 端點、匯出項目、事件契約 |
| `tunnels.md` | 跨模組實體參照（自動偵測） |
| `modules/*.md` | 各模組深度摘要 |

**4 層記憶堆疊**（靈感來自 [mempalace](https://github.com/milla-jovovich/mempalace)）：

| 層級 | 內容 | Token 數 | 載入時機 |
|-------|---------|--------|-------------|
| L0: 身份識別 | 名稱 + 類型 + 用途 | 約 50 | 始終載入 |
| L1: 基礎 | 標記的慣例 + 模式 | 約 200 | 始終載入 |
| L2: 空間記憶 | 網站地圖 + 架構 + 相關模組 | 約 500 | 審查/查詢時 |
| L3: 深度搜尋 | 完整 API 表面 + 所有模組 | 約 800+ | 協調器啟動時 |

**成果**：審查喚醒成本從約 150K token 降低到約 250 token。

PKB 在每次審查後自動更新（背景執行，不阻塞），並使用 **mtime 偵測**跳過未變更的模組。

### 4. 跨倉庫相依性偵測

五個內建掃描器 + 自訂外掛：

| 掃描器 | 偵測項目 | 信心度 |
|---------|---------|------------|
| `docker-compose` | 服務關係 | 高 |
| `shared-db` | 共用資料庫的專案 | 高 |
| `gateway-routes` | API 閘道路由 | 中 |
| `shared-packages` | 內部 npm/gem 套件 | 高 |
| `api-calls` | 環境變數 API 主機參照 | 低 |

```bash
mra scan                 # 自動偵測相依性
mra deps my-api          # 顯示相依性樹狀圖
mra graph --mermaid      # 視覺化相依性圖表
```

### 5. 審查品質評估

對比人工審查者衡量審查準確度：

```bash
mra eval-review my-api --pr 123
```

比較 MRA 的發現與同一 PR 上的人工審查：
- **精確度 (Precision)** — MRA 發現中有多少百分比是真正的問題？
- **召回率 (Recall)** — MRA 捕捉到多少百分比的人工發現？
- **F1 分數** — 平衡的品質指標

報告儲存於 `.collab/eval/` 以供趨勢追蹤。

### 6. Docker 環境與測試

```bash
mra db setup                     # 啟動資料庫容器 + 匯入備份
mra test my-api                  # 自動偵測測試策略
mra test my-api --integration    # 完整整合測試
mra watch my-api                 # 檔案變更時自動測試
```

---

## 教學指南

### 首次設定

<details>
<summary><strong>逐步工作區初始化</strong></summary>

#### 1. 前置需求

| 工具 | 安裝方式 |
|------|---------|
| `git` | macOS 已預裝 |
| `docker` | [Docker Desktop](https://docker.com) 或 [OrbStack](https://orbstack.dev) |
| `jq` | `brew install jq` |
| `gh` | `brew install gh` 然後 `gh auth login` |
| `claude` | [claude.ai/code](https://claude.ai/code) |

選用：`yq`（`brew install yq`）、`fswatch`（`brew install fswatch`）

#### 2. 初始化工作區

```bash
gh auth login                    # 如需要請切換到組織帳號
mra init ~/workspace --git-org git@github.com:my-org
```

這會複製倉庫、掃描 docker-compose 檔案、偵測相依性，並建立工作區別名。

#### 3. 設定資料庫

```bash
mkdir -p ~/workspace/dumps
cp /path/to/myapp_db.sql.bz2 ~/workspace/dumps/
mra db setup
```

db.json 格式：

```json
{
  "databases": {
    "mysql": {
      "engine": "mysql",
      "version": "5.7",
      "platform": "linux/amd64",
      "port": 3306,
      "password": "123456",
      "schemas": {
        "myapp_db": {
          "source": "./dumps/myapp_db.sql.bz2",
          "usedBy": ["my-api", "backend-api"]
        }
      }
    }
  }
}
```

支援格式：`.sql`、`.sql.gz`、`.sql.bz2`、`.sql.xz`、`.sql.zst`、`.dump` | 引擎：`mysql`、`postgres`

#### 4. 驗證並建立快照

```bash
mra doctor                       # 健康檢查
mra snapshot "initial-setup"     # 安全檢查點
```

</details>

### 日常開發

<details>
<summary><strong>常見工作流程與指令</strong></summary>

```bash
# 早晨檢查
mra status                       # 所有專案總覽
mra diff                         # 未提交/未推送的變更
mra dashboard                    # 互動式 TUI

# 跨專案開發
mra my-api --with-deps           # 啟動協調器
# 給 Claude 一個任務：
# > "將 order API 的回傳欄位從 data 改為 items，並同步所有使用者"

# 快速查詢（不需互動式對話）
mra ask my-api "list all order-related API endpoints"
mra ask my-api --with-deps "API dependencies between my-api and frontend"

# 程式碼品質
mra lint frontend-app            # 檢查 BLOCKER 規則
mra lint --all                   # 所有前端專案

# 推送前
mra snapshot "before-push"
mra review my-api --pr 123       # 行內 PR 審查

# 出問題了？
mra rollback my-api              # 還原至最新快照
```

#### 多專家計畫

```bash
mra plan my-api "Migrate session tokens to JWT"
```

五位領域專家各自獨立提出實作策略，接著由綜合器合併為一份統一計畫（合併後的檔案清單、依風險排序的疑慮、執行步驟）。輸出會寫到 stdout — 可透過管線導向檔案保存。

#### 測試品質稽核

```bash
mra test-audit frontend-app        # 以 Kent Beck 11 條原則稽核所有測試檔
MRA_AUDIT_PARALLEL=3 mra test-audit frontend-app  # 限制同時稽核的併發數
```

會自動尋找 `*.test.*`、`*_test.*`、`*.spec.*` 檔案（排除 `node_modules`、`dist`、`build`、`vendor`、`.git`），並透過 `test-architect` persona 針對 Kent Beck 的 11 條測試原則逐一稽核。

</details>

### 程式碼審查

<details>
<summary><strong>本機審查、PR 行內評論、CI 自動化</strong></summary>

```bash
# 本機終端機審查
mra review my-api                         # 自動選擇策略
mra review my-api --base development      # 對比指定分支
mra review my-api --strategy debate       # 強制完整審查

# GitHub PR 行內審查
mra review my-api --pr 123               # 發表行內評論
mra review my-api --pr 123 --model opus  # 使用更強大的模型

# 自動化 CI 審查
mra ci my-api --with-review              # 產生 GitHub Actions 工作流程
```

將 `ANTHROPIC_API_KEY` 加入倉庫密鑰。工作流程會在每個 PR 觸發、發表行內評論，並在後續推送時更新。

**Token 最佳化策略：**
- PKB 整合（知識文件取代完整程式碼庫）
- 模型分層（haiku 用於投票，sonnet 用於分析）
- 聚焦上下文（僅載入變更檔案所在目錄）
- 發現壓縮（後續輪次僅保留摘要）

</details>

### 專案知識庫

<details>
<summary><strong>產生、使用並維護專案知識</strong></summary>

```bash
# 產生 PKB（一次性投入）
mra analyze my-api
mra analyze my-api --model haiku    # 模組摘要使用較便宜的模型

# PKB 自動被所有指令使用
mra review my-api --pr 123          # 使用 PKB 上下文
mra my-api --with-deps              # 協調器取得完整 PKB
mra ask my-api "how does auth work?"  # 標準層級 PKB
```

每次審查後，PKB 自動更新：
- 變更的模組會更新摘要（背景執行，使用 haiku）
- 新檔案會更新網站地圖
- CRITICAL/HIGH 的發現會被記錄為 conventions.md 中的 `[DECISION]` 標籤
- 重新產生跨模組參照的通道連結

若不存在 PKB，則回退為載入完整程式碼庫。

</details>

### 新成員加入

<details>
<summary><strong>與新團隊成員分享工作區設定</strong></summary>

從 `<workspace>/.collab/` 分享這些檔案：

| 檔案 | 必要性 |
|------|----------|
| `repos.json` | 是 |
| `db.json` | 是 |
| `manual-deps.json` | 選用 |
| SQL 備份檔案 | 是 |

新成員步驟：

```bash
git clone <mra-repo> ~/multi-repo-agent
cd ~/multi-repo-agent && bash install.sh && source ~/.zshrc
gh auth login

mkdir -p ~/workspace/.collab ~/workspace/dumps
cp /from/teammate/repos.json ~/workspace/.collab/
cp /from/teammate/db.json ~/workspace/.collab/
cp /from/teammate/*.sql.bz2 ~/workspace/dumps/

mra init ~/workspace --git-org git@github.com:my-org
mra db setup
mra doctor
```

產生範本：`mra template`

</details>

---

## 指令參考

<details>
<summary><strong>全部 28 個指令</strong></summary>

### 核心

| 指令 | 說明 |
|---------|-------------|
| `mra init <path> --git-org <url>` | 初始化工作區 |
| `mra scan` | 重新掃描相依性 |
| `mra deps [project]` | 顯示相依性圖表 |
| `mra status` | 工作區總覽 |
| `mra diff` | 跨倉庫差異摘要 |
| `mra log [project]` | 操作歷史記錄 |

### AI 與開發

| 指令 | 說明 |
|---------|-------------|
| `mra <project...> [--with-deps]` | 啟動 Claude 協調器 |
| `mra ask <project> "<question>"` | 程式碼庫查詢 |
| `mra export [project]` | 匯出專案上下文 |

### 程式碼審查與分析

| 指令 | 說明 |
|---------|-------------|
| `mra review <project> [--pr N] [--strategy S] [--base ref] [--personas]` | 程式碼審查（加上 --personas 啟用 5 位具名專家） |
| `mra plan <project> "<task>" [--model M]` | 多專家實作計畫 |
| `mra test-audit <project> [--model M]` | Kent Beck 11 條原則測試稽核 |
| `mra analyze <project> [--model M]` | 產生 PKB |
| `mra eval-review <project> --pr N [--baseline file]` | 評估審查品質 |

### Docker 與測試

| 指令 | 說明 |
|---------|-------------|
| `mra db setup\|status\|import` | 資料庫管理 |
| `mra test <project> [--integration\|--mock]` | 執行測試 |
| `mra setup <project\|--all>` | 安裝相依套件 |
| `mra watch <project>` | 檔案變更時自動測試 |

### 品質與安全

| 指令 | 說明 |
|---------|-------------|
| `mra doctor` | 健康檢查 |
| `mra lint <project\|--all>` | JS/TS BLOCKER 規則 |
| `mra cost [--reset]` | API 用量追蹤 |
| `mra snapshot [name]` | 建立檢查點 |
| `mra rollback <project> [name]` | 還原快照 |

### CI/CD 與協作

| 指令 | 說明 |
|---------|-------------|
| `mra ci <project> [--with-review]` | 產生 GitHub Actions |
| `mra federation publish\|subscribe\|verify` | 跨團隊契約 |
| `mra notify setup\|test` | Webhook 通知 |

### 工具

| 指令 | 說明 |
|---------|-------------|
| `mra graph [--mermaid\|--dot]` | 相依性視覺化 |
| `mra dashboard` | 互動式 TUI |
| `mra open <project>` | 在 IDE 中開啟 |
| `mra config <key> <value>` | 設定 |
| `mra clean` | 清理 |

</details>

---

## AI 代理團隊

| 代理 | 角色 |
|-------|------|
| **協調器 (Orchestrator)** | 協調跨專案變更、派遣子代理 |
| **PM 代理 (PM Agent)** | 需求分析、任務拆解 |
| **子代理 (Sub-Agent)** | 為每個專案撰寫程式碼、執行測試、提交 |
| **程式碼審查者 (Code Reviewer)** | 審查差異的正確性、安全性、API 一致性 |
| **PR 審查者 (PR Reviewer)** | 以跨專案上下文審查整個 PR |
| **PKB 分析師 (PKB Analyzer)** | 深度專案分析、產生知識文件 |

### 辯論審查代理

| 代理 | 模型 | 角色 |
|-------|-------|------|
| 影響分析師 (Impact Analyst) | sonnet | 搜尋破損的參照、廢棄程式碼 |
| 品質稽核員 (Quality Auditor) | sonnet | 檢查模式、安全性、型別安全 |
| 投票者 A/B (Voter A/B) | haiku | 對發現池投票 保留/捨棄 |
| 綜合器 (Synthesizer) | sonnet | 將存活的發現合併為 JSON |

所有審查代理都是**唯讀模式**（寫入工具已停用）。

---

## 架構

```
mra CLI（純 shell，除 jq/git/docker/gh 外零執行時相依性）
  |
  +-- 工作區管理器
  |     倉庫同步、相依性掃描（5 個掃描器）、資料庫設定
  |
  +-- 專案知識庫 (PKB)
  |     L0-L3 記憶堆疊、自動分類標籤、
  |     通道連結、基於 mtime 的增量更新
  |
  +-- 程式碼審查引擎
  |     自動策略選擇、信箱投票辯論、
  |     唯讀代理、模型分層、評估框架
  |
  +-- Claude 協調器
  |     多倉庫上下文、PM/子代理/審查者派遣、
  |     Docker 測試執行、API 變更偵測
  |
  +-- 整合
        MCP 伺服器（9 個工具）、GitHub Actions、聯盟、Slack/Discord
```

---

## 整合

<details>
<summary><strong>MCP 伺服器、GitHub Actions、聯盟、通知</strong></summary>

### MCP 伺服器

```bash
cd ~/multi-repo-agent/mcp-server && npm install && npm run build
claude mcp add mra node ~/multi-repo-agent/mcp-server/dist/index.js
```

9 個工具：`mra_status`、`mra_deps`、`mra_ask`、`mra_export`、`mra_diff`、`mra_doctor`、`mra_graph`、`mra_scan`、`mra_test`

### GitHub Actions

```bash
mra ci my-api --with-review    # 產生 CI + 審查工作流程
```

### 聯盟 (Federation)

```bash
mra federation publish my-api              # 發布 API 契約
mra federation subscribe https://url.json  # 訂閱
mra federation verify                      # 檢查相容性
```

### 通知

```bash
mra notify setup    # 建立 webhook 設定（Slack/Discord）
mra notify test     # 傳送測試通知
```

</details>

---

## 設定

<details>
<summary><strong>工作區與全域設定</strong></summary>

所有工作區設定位於 `<workspace>/.collab/`：

| 檔案 | 用途 | 可分享 |
|------|---------|-----------|
| `repos.json` | 要複製哪些倉庫 | 是 |
| `db.json` | 資料庫設定 | 是 |
| `dep-graph.json` | 自動產生的相依性圖表 | 否 |
| `manual-deps.json` | 手動相依性覆寫 | 是 |
| `notify.json` | Webhook 設定 | 是 |
| `eval/` | 審查評估報告 | 否 |

全域設定：`~/multi-repo-agent/config.json`

```json
{
  "autoScan": true,
  "depthDefault": 1,
  "outputLanguage": "繁體中文台灣用語",
  "subAgentWorkflow": { "reviewLoopMax": 3, "autoCommit": true, "autoPR": true }
}
```

</details>

---

## 發展藍圖

### 近期新增

- 自動策略審查（輕量/標準/辯論）
- 信箱投票辯論系統
- 專案知識庫與 L0-L3 記憶堆疊
- 自動分類標籤（`[CONVENTION]`/`[PATTERN]`/`[DECISION]`）
- 跨模組通道連結
- 基於 mtime 的增量 PKB 更新
- 審查評估框架（精確度/召回率/F1）
- 唯讀審查代理
- 審查中的決策自動擷取

### 未來規劃

- Playwright E2E 測試整合
- 網頁儀表板（瀏覽器版相依性圖表）
- PKB 語意搜尋（基於嵌入向量的檢索）
- 跨倉庫 PKB 連結（共用型別契約）
- 評估趨勢儀表板

---

## 授權條款

MIT
