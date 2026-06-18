# 快照與回滾

擷取並還原工作區狀態,讓高風險操作可逆。

```bash
mra snapshot before-refactor       # 擷取具名狀態快照
mra snapshots                      # 列出所有快照
mra rollback my-api before-refactor   # 還原單一專案(摧毀前會詢問)
mra rollback --all before-refactor    # 還原所有專案(整批單次確認)
```

## 指令

| 指令 | 用途 |
|------|------|
| `mra snapshot [name]` | 建立狀態快照(可命名)。 |
| `mra snapshots` | 列出所有快照。 |
| `mra rollback <project> [name] [--force] [--ignore-integrity]` | 將單一專案回滾到快照。摧毀現狀前會先詢問。 |
| `mra rollback --all [name] [--force] [--ignore-integrity]` | 回滾所有專案,整批單次確認。 |

## 旗標

| 旗標 | 效果 |
|------|------|
| `--force` | 跳過確認提示。 |
| `--ignore-integrity` | 即使快照完整性檢查失敗仍繼續(謹慎使用)。 |

::: warning
回滾具破壞性 —— 會以快照覆蓋目前工作狀態。除非加 `--force`,否則 mra 會在摧毀前詢問。
:::
