# mra review

具情境感知的 code review，依 diff 大小自動選擇策略。

## 策略

| 策略 | 時機 | 方式 |
|------|------|------|
| **Light** | < 50 行、≤ 3 個檔案 | 單回合、2 turns（約 15 秒） |
| **Standard** | < 300 行 | 單回合、3 turns（約 30 秒） |
| **Debate** | 大型 diff 或 API 變更 | 2 位分析員 + mailbox 投票（約 3 分鐘） |

```bash
mra review my-api                     # 預設使用 Codex
mra review my-api --pr 123            # post inline comments
mra review my-api --provider claude --strategy debate   # 強制使用 Claude debate mode
mra review my-api --base development  # compare against a specific branch
```

## Provider

Review 預設使用 Codex。Admin 可以切換預設：

```bash
mra config review.providerMode codex
mra config review.providerMode claude
mra config review.providerMode fallback
mra config review.providerMode dual
```

CLI 的 `--provider` override 預設會被阻擋，除非開啟 `review.allowUserOverride` 或設定 `MRA_REVIEW_ADMIN_OVERRIDE=1`。`fallback` 會先跑 primary 再 fallback 到 secondary；`dual` 會跑兩個 provider 並合併 standard single-pass findings。目前 Codex 先走 single-pass review；debate 與 personas 仍維持 Claude-only，等後續 providerized debate phase。

新安裝預設使用 Codex + standard；未版本化的舊設定會保留 Claude 行為，
直到管理者明確遷移。Codex 會從 MRA 控制的 trusted cwd 執行，並只讀取
移除原生 instruction surface 的 sanitized snapshot；repository 內的 AGENTS、
Claude rules 與 skills 只會作為 untrusted review context。

機器整合請使用 `mra integration describe|doctor|review`。Protocol v1 僅分析、
輸出綁定 SHA 的 JSON artifact，且不接收 GitHub credential 或 approval intent。
Protocol v1 只宣告 Codex，因為目前只有 Codex 具備強制 sanitized execution。
Claude、fallback 與 dual 仍可用於一般 review，但不能作為 approve 授權證據。

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
