# 常見問題

## 為什麼用 bash 而不是 Python / Node？

零執行期相依。筆電上只要有 `git`、`jq`、`docker`、`gh` 就能跑。每多一個語言 runtime 對只想執行 CLI 的使用者都是阻力。

## mra 會把我的程式碼送給 Anthropic 嗎？

只送你明確納入 context window 的檔案。PKB 文件設計上就是讓你可以檢視送出的內容。所有唯讀流程的 `claude -p` 呼叫都帶 `--disallowedTools "Write,Edit,NotebookEdit"`。

## mra 怎麼知道我的 repo 關係？

5 個 scanner（docker-compose、shared-db、gateway-routes、shared-packages、api-calls）自動推論圖形。可以在 `.collab/manual-deps.json` 覆寫。

## 我可以新增自己的 persona 嗎？

可以。依照 `ROLE/STYLE/FOCUS/METHOD/OUTPUT FORMAT` 格式把一個 markdown 丟到 `agents/personas/<name>.md`，會自動偵測。

## `--personas` 會取代 debate 嗎？

不會 — 它是一個可選的替代策略。預設仍是自動選擇（light / standard / debate）。建議在安全關鍵 PR 或跨 repo API 變更時才用 `--personas`。

## 費用大概多少？

Debate review：依 diff 大小每個 PR 約 $0.05–$0.20。Persona review：約 $0.15–$0.40（5 agent vs. 2）。`mra analyze` 對 500 個檔案的專案：一次約 $0.50。

用 `mra cost` 追蹤。

## Bash 版本低於 4.3 怎麼辦？

`wait -n` 會回退到對最舊的 pid 進行 blocking wait。所有新 lib 在 macOS bash 3.2 上都能正常執行。

## Log 在哪？

每個專案一份：`.collab/logs/<project>/<date>.log`。
