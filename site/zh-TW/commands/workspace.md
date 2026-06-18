# 工作區與依賴圖

建立工作區、建立跨 repo 依賴關係,以及日常導覽的指令。

```bash
mra init ~/workspace --git-org git@github.com:my-org   # clone repos、掃描、偵測依賴、建立別名
mra scan                       # 重新偵測依賴(新增 repo 後執行)
mra deps my-api                # 顯示單一專案的依賴圖
mra graph --mermaid            # 以 Mermaid 輸出依賴圖(或 --dot)
```

## 建置與設定

| 指令 | 用途 |
|------|------|
| `mra init <path> --git-org <url>` | 初始化工作區:clone repos、掃描 `docker-compose`、偵測依賴、建立別名。狀態存於 `<path>/.collab/`。 |
| `mra scan [path]` | 重新掃描依賴圖。clone / 新增 repo 後務必執行,mra 才會登錄它。 |
| `mra config <key> <value>` | 設定工作區設定值。 |
| `mra alias <name> <path>` | 建立工作區別名,方便快速存取專案。 |
| `mra setup <project\|--all>` | 自動安裝專案(或全部)的相依套件。 |
| `mra template [repos\|db\|deps\|all]` | 產生設定檔範本,快速起步。 |

## 檢視與導覽

| 指令 | 用途 |
|------|------|
| `mra deps [project]` | 顯示依賴圖(全部 repo,或單一專案)。 |
| `mra graph [--mermaid\|--dot]` | 視覺化依賴圖,供文件 / 圖表使用。 |
| `mra open <project> [--with-deps]` | 在 IDE 開啟專案(可一併開啟其依賴)。 |
| `mra doctor [project]` | 驗證環境健康(工具、容器、設定)。 |
| `mra clean [--logs-older-than Nd]` | 清除孤兒容器與過舊日誌。 |

## 上架新 repo

```bash
cd ~/workspace
git clone <repo-url>     # 或讓 `mra sync` clone 已登錄在 .collab/repos.json 的 repo
mra scan                 # 登錄進依賴圖
mra alias myrepo ~/workspace/myrepo
mra doctor myrepo        # 環境健檢
```
