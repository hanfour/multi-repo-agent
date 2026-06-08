# Personas

具名領域專家 prompt 片段，供 `mra review --personas`、`mra plan`、`mra test-audit` 使用。

## 結構

`agents/personas/` 下每個 persona 檔案遵循固定格式：

```md
ROLE: <專家稱號>
STYLE: <語氣 / 靈感來源>

FOCUS:
- <關注點>
- <關注點>

METHOD:
1. <步驟>
2. <步驟>

OUTPUT FORMAT:
- [CRITICAL] `file:line` — <問題>
- [HIGH] `file:line` — <問題>
- [MEDIUM] `file:line` — <建議>
```

## 嚴重度分級

| 等級 | 意義 |
|------|------|
| CRITICAL | 必須擋 merge — 可被利用、已壞、或會直接影響 production |
| HIGH | 強烈建議修正，有可重現的影響 |
| MEDIUM | 打磨 / defense-in-depth / 可讀性 |

若某個等級不適用於該 persona 領域，persona 可以省略（例如 `refactoring-sage` 幾乎不會產生 CRITICAL）。

## 內建 personas

| Persona | 靈感來源 | 關注 |
|---------|---------|------|
| `security-auditor` | Troy Hunt | 密鑰外洩、注入、認證、反序列化 |
| `api-contract-guardian` | 跨 repo reviewer | 簽章漂移、回應格式變動 |
| `performance-hawk` | Vercel 效能工程師 | N+1、hot-path I/O、bundle 肥大 |
| `refactoring-sage` | Martin Fowler | Code smell、命名、內聚、死程式碼 |
| `test-architect` | Kent Beck | 11 條測試原則 |

## 新增自己的 persona

把一個新的 markdown 丟到 `agents/personas/<name>.md`。`lib/personas.sh` 會自動偵測。任何支援 persona 的指令都可以用該 basename 引用。

## 範圍界線

每個 persona 都有 `SCOPE NOTE:` 區塊避免互相重疊 — 例如 `performance-hawk` 負責 runtime cost，`api-contract-guardian` 負責 shape / identity。

## 唯讀保證

所有 persona agent 啟動時都帶 `--disallowedTools "Write,Edit,NotebookEdit"`。它們只能 grep / 讀取，不能寫入。
