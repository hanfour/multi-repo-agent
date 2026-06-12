# mra plan

召集 5 位領域專家各自獨立提出實作策略，再綜整成一份計畫。

```bash
mra plan my-api "Migrate session tokens to JWT"
```

## 流程

1. **平行派工** — 5 個 persona 各自收到任務 + PKB 脈絡 + 專案程式碼存取權。
2. **獨立建議** — 每位專家各寫一份策略（要動的檔案、依 CRITICAL/HIGH/MEDIUM 排序的風險、必要的測試）。
3. **綜整** — 最後一輪合併重疊的檔案、依嚴重度排序風險並標註出處專家，輸出一份編號的 TODO 清單。

## 輸出格式

```
# Unified Plan: Migrate session tokens to JWT

## Consolidated Files
- `lib/auth.ts` — rewrite token issuance
- `lib/middleware.ts` — validate signatures

## Risks (sorted)
- [CRITICAL] [security-auditor] JWT secret rotation strategy missing
- [HIGH]     [api-contract-guardian] 401 response shape changed

## Required Tests
- Integration: round-trip JWT over /login → /me

## Execution Steps
1. Add JWT secret to env
2. ...
```

## 選項

| 旗標 | 作用 |
|------|------|
| `--model sonnet` | 預設；需要更深入的推理時改用 `opus` |
| `--dual` | 每個 persona 同時跑 claude 與 codex，再調和兩邊結果 |

## --dual（多模型 council）

加上 `--dual` 後，每個 persona 會**同時**透過 `claude` 與 `codex` 兩個 CLI 執行。綜整器接著調和兩個模型的提案 — 標出雙方一致之處、揭露雙方分歧之處 — 讓你得到跨模型共識，而不是單一模型的觀點。

```bash
mra plan my-api "Migrate session tokens to JWT" --dual
```

需要 `PATH` 上有 `codex` CLI。

要保存結果可以 pipe 到檔案：

```bash
mra plan my-api "Migrate session tokens to JWT" > plans/jwt-migration.md
```
