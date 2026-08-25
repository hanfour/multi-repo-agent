---
id: common-env-loading-conditional-gate
layer: common
frameworks: ["prisma@>=2"]
severity_default: HIGH

---
## 觸發訊號
diff 修改了決定「是否載入 / 如何處理環境變數（.env）」的條件判斷式，典型型態如：
- `NODE_CLIENT && tryLoadEnvs(envPaths, ...)` 這類布林條件被改動，尤其是加入或移除 `adapter`、`NODE_CLIENT`、edge/driver-adapter 相關判斷時（如 `getPrismaClient.ts`）
- 決定要不要對 `.env` 內容做額外處理（如 `dotenvExpand`、`conflictCheck` 模式）的呼叫參數被改動
- 為 edge/driver-adapter 情境挑選要保留哪些環境變數子集的邏輯（如 `buildInjectableEdgeEnv.ts` 的 `loadSelectedEnvVars` / `getEmptyEnvObjectForVars`）被改動，但沒有同步更新周邊註解說明

## 判準
這類條件式通常是塞在一行內的布林運算（`A && B && fn()`），語意容易被寫反或漏改：新增一個 runtime target（driver adapter、edge）時，工程師常常忘記把新條件納入既有的 `NODE_CLIENT` 判斷，導致邏輯方向錯誤（例如「driver adapter 情境不該讀本機 .env」卻寫成「只有 driver adapter 才讀」）。這種錯誤不會在型別檢查或一般 happy-path 測試中被抓到，因為分支覆蓋通常只驗證最常見的 Node 情境，而遺漏 adapter/edge 組合；後果是機密資訊被載入不該讀取的環境，或是合法情境下環境變數靜默載入失敗，且往往要靠追蹤程式原始意圖（而非讀 diff 本身）才能發現方向寫反。

## 嚴重度
CRITICAL：條件式改動導致環境變數 / 機密在不該讀取的 runtime（如 edge runtime、driver-adapter client）被載入或外洩，或是導致正式連線設定在生產情境下靜默失敗。
HIGH：新增/修改了環境變數載入的閘門邏輯（例如新增 adapter+node 或 edge+node 的組合），但沒有對應測試覆蓋新的 runtime 組合，有靜默回歸風險。
MEDIUM：描述環境變數載入行為的註解/文件在閘門邏輯改動後沒有同步更新，或留下未解決的 TODO 質疑既有邏輯是否等價（如「這不就等於 xxx 嗎？」的疑問未被處理）。

## 反例（不該報）
- 純格式/空白調整，未改變條件式邏輯本身（例如移除型別註解裡多餘的空格）
- 與環境變數載入閘門無關的內部變數名稱拼字修正（如 `__prismaRawParamaters__` → `__prismaRawParameters__`）
- 在連線字串參數的 `handledParameters` 允許清單中新增參數，但該清單只影響 debug log 是否印出「未知參數」警告，不影響環境變數是否被載入的邏輯

## 出處
- https://github.com/prisma/prisma/pull/28813#discussion_r3644402710
- https://github.com/prisma/prisma/pull/21286#discussion_r1341429495
- https://github.com/prisma/prisma/pull/18118#discussion_r1118871518
- https://github.com/prisma/prisma/pull/17156#discussion_r1081691715
- https://github.com/prisma/prisma/pull/16655#discussion_r1041281877
- https://github.com/prisma/prisma/pull/15645#discussion_r986547943
- https://github.com/prisma/prisma/pull/14195#discussion_r936965150
- https://github.com/prisma/prisma/pull/13512#discussion_r888916644
- https://github.com/prisma/prisma/pull/4121#discussion_r516096550
- https://github.com/prisma/prisma/pull/3330#discussion_r484777995
