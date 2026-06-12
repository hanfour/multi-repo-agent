# mra review

具情境感知的 code review，依 diff 大小自動選擇策略。

## 策略

| 策略 | 時機 | 方式 |
|------|------|------|
| **Light** | < 50 行、≤ 3 個檔案 | 單回合、2 turns（約 15 秒） |
| **Standard** | < 300 行 | 單回合、3 turns（約 30 秒） |
| **Debate** | 大型 diff 或 API 變更 | 2 位分析員 + mailbox 投票（約 3 分鐘） |

```bash
mra review my-api                     # auto-select
mra review my-api --pr 123            # post inline comments
mra review my-api --strategy debate   # force debate mode
mra review my-api --base development  # compare against a specific branch
```

## --personas（選擇性啟用）

把兩位通用 debate agent 換成 5 位具名領域專家：

```bash
mra review my-api --personas
```

| Persona | 關注 |
|---------|------|
| `security-auditor` | 密鑰、注入、認證（Troy Hunt） |
| `api-contract-guardian` | 跨 repo 簽章漂移 |
| `performance-hawk` | N+1、hot-path I/O、bundle 肥大 |
| `refactoring-sage` | Code smell、命名、內聚（Fowler） |
| `test-architect` | Kent Beck 11 條原則 |

完整設計見 [Personas](/zh-TW/features/personas)。

## 唯讀保證

所有 review agent 都以 `--disallowedTools "Write,Edit,NotebookEdit"` 執行。它們無法修改檔案 — 只能讀取與回報。
