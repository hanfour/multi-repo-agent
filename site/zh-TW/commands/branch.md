# mra branch

跨多個 repo 管理同一條功能分支,再依相依順序一起開 PR、合併 PR。

```bash
mra branch status                 # 哪些 repo 需要注意
mra branch new feature/login      # 在每個 repo 建立該分支
mra branch switch feature/login   # 把每個 repo 切換到該分支
mra branch pr                     # push 分支 + 開 PR(相依先)
mra branch merge --wait-ci        # 每個 PR 等 CI 綠燈後合併
```

## status

跨 repo 總覽每條分支的狀態(ahead/behind/dirty/PR 狀態)。

```bash
mra branch status              # 預設:只列需要注意的 repo
mra branch status --all        # 列出每個 repo
mra branch status --fetch      # 先 fetch remote 以取得正確的 ahead/behind
mra branch status --json       # 所有 repo 的機器可讀陣列
```

## new / switch

```bash
mra branch new <name>          # 從每個 repo 的 base 分支建立 <name>
mra branch switch <name>       # 在每個擁有該分支的 repo 上 checkout <name>
```

## pr

依相依順序跨 repo push 功能分支並開 PR,讓下游 PR 能引用上游 PR。

```bash
mra branch pr                          # 所有有領先 commit 的 repo
mra branch pr --base develop           # 指定非預設的 base
mra branch pr --dry-run                # 預覽,不實際 push
mra branch pr my-api frontend-app      # 只處理這個子集
```

## merge

合併開啟中的 PR,以 mergeable 狀態 + CI 為門檻。依相依順序執行。

```bash
mra branch merge                               # 合併每個就緒的 PR
mra branch merge --strategy squash             # merge | squash | rebase
mra branch merge --wait-ci                     # 輪詢 CI,綠燈才合併每個 PR
mra branch merge --wait-ci --ci-timeout 1200   # 最多等 CI 20 分鐘
mra branch merge --delete-branch               # 合併成功後刪除 remote 分支
mra branch merge my-api                        # 只處理這個子集
```

| 旗標 | 作用 |
|------|------|
| `--strategy merge\|squash\|rebase` | 合併方式(預設 `merge`) |
| `--wait-ci` | 輪詢每個 PR 的 checks,綠燈才合併 |
| `--ci-timeout <sec>` | 等待 CI 的最長秒數(需搭配 `--wait-ci`) |
| `--delete-branch` | 合併成功後刪除 remote 分支 |
| `--dry-run` | 回報將合併的內容,但不實際合併 |
| `[repos…]` | 限定處理部分 repo |
