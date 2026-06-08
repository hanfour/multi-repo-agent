# mra sync

一次 clone 或 pull 工作區的每一個 repo。具分支感知:每個 repo 都在它目前所在的分支上同步。

```bash
mra sync                # clone 缺少的 repo,其餘 pull
mra sync --safe         # 僅 fast-forward(絕不覆寫本地工作)
mra sync --push         # pull 後一併 push 本地 commit
mra sync --review       # 自動 review 每次 pull 帶進來的變更
```

## 模式

| 旗標 | 作用 |
|------|------|
| `--safe` | 僅 fast-forward 的 pull;需要 merge 的 repo 會被跳過並回報,不會強制更新 |
| `--push` | 同步後,push 每個 repo 目前的分支 |
| `--review` | 對新 pull 進來的變更跑一次 code review(不可與 `--json` 併用) |
| `--dry-run` | 只印出將會發生的動作,不碰任何 repo |
| `--json` | 輸出機器可讀的結果陣列(見下) |

## JSON 輸出

`--json` 會對每個 repo 印出一個物件到 stdout —— worker log 走 stderr,所以 stdout 維持為有效 JSON:

```json
[
  { "repo": "my-api", "action": "pulled", "ok": true },
  { "repo": "frontend-app", "action": "skipped", "ok": true }
]
```

`action` 為 `cloned` / `pulled` / `pushed` / `skipped` 其一;當該 repo 的操作失敗時 `ok` 為 `false`。可 pipe 進 `jq` 來把關其他工具:

```bash
mra sync --safe --json | jq -e 'all(.ok)'
```

`--json` 可用於預設、`--safe`、`--push` 模式 —— 但不能與 `--review` 併用。
