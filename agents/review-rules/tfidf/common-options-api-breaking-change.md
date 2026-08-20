---
id: common-options-api-breaking-change
layer: common
frameworks: ["typescript@*"]
severity_default: HIGH
---
## 觸發訊號
diff 中對「公開 API（exported class 建構子、decorator factory、builder method、client options 型別）」的 options 參數做了以下任一種改動：
- 型別被放寬成 `any` / `any[]`（例如 `urls?: string[]` 改成 `urls?: any[]`），且沒有補上對應的執行期驗證
- options 的 generic 型別從通用型別（如 `Record<string, any>`）收窄成單一實作專屬的介面（例如把原本泛用的 gateway options 收窄成 socket.io 專屬的 `GatewayMetadata`，導致換成其他 adapter/實作時無法使用）
- options 物件被多轉發一層傳給底層函式呼叫（例如原本只把 `options` 傳給某個函式，現在多傳一個新參數或多轉發到另一個原本沒收到它的呼叫點），因而改變了底層行為
- 上述改動沒有伴隨 changelog、`@deprecated` 標記、migration note，或 PR 討論串裡對「這是否為 breaking change」的明確結論

## 判準
套件的 options 型別與轉發行為是使用者程式碼與型別檢查器之間的契約。放寬型別會讓原本編譯期就能擋下的錯誤輸入變成執行期才爆炸；收窄 generic 會讓原本合法的替代實作（不同 adapter、不同底層引擎）在升級後失去型別相容性；多轉發一層 options 給底層函式，等於在不改變函式簽章的情況下偷偷改變了行為，使用者完全看不出來。這些改動對函式庫維護者來說都是高風險：它們往往不會被單元測試抓到（測試通常只涵蓋新行為），卻可能在 minor/patch 版本升級時讓下游專案出現非預期行為或編譯失敗。resenior reviewer 在這幾則意見裡反覆問「這會不會是 breaking change」，就是因為答案沒辦法從程式碼本身看出來，必須由作者主動說明。

## 嚴重度
CRITICAL：型別放寬（如 `string[] → any[]`）直接移除了原本會被 TypeScript 擋下的無效輸入保護，且沒有補上對應的執行期驗證邏輯
HIGH：新增的轉發行為改變了底層函式實際收到的參數（例如多傳一個原本沒有的 `options` 給某個呼叫），可能改變既有使用者的執行結果，PR 討論中未確認這是否為 breaking change
MEDIUM：options 的 generic 型別從通用介面收窄成單一實作專屬型別，限制了其他合法實作（不同 adapter/引擎）的可用性，但尚未造成既有程式碼編譯失敗

## 反例（不該報）
- 型別放寬或行為改動只發生在未匯出（non-exported）的內部型別或工具函式，不影響套件的公開介面
- 這個改動本來就是計畫中的 major version breaking change，且已在 changelog / migration guide / PR 描述中明確說明
- 新增的 options 欄位本身是新增的、可選的（optional），並附帶完整的型別與執行期驗證與清楚的錯誤訊息（例如替新增的 `queryPlanCacheMaxSize` 補上型別檢查與範圍檢查），不影響任何既有呼叫方式
- 只是重新匯出（re-export）既有型別到新的模組路徑以解決循環依賴，型別結構本身未改變

## 出處
- https://github.com/nestjs/nest/pull/14606#discussion_r2079076067
- https://github.com/nestjs/nest/pull/14305#discussion_r1881669518
- https://github.com/nestjs/nest/pull/12764#discussion_r1397167863
- https://github.com/nestjs/nest/pull/12622#discussion_r1368054543
- https://github.com/nestjs/nest/pull/12622#discussion_r1367506401
- https://github.com/nestjs/nest/pull/10597#discussion_r1031899649
- https://github.com/nestjs/nest/pull/8787#discussion_r769532377
- https://github.com/nestjs/nest/pull/8787#discussion_r769226902
- https://github.com/nestjs/nest/pull/8787#discussion_r769122832
- https://github.com/nestjs/nest/pull/5609#discussion_r514103060
- https://github.com/nestjs/nest/pull/251#discussion_r151696042
- https://github.com/nestjs/nest/pull/251#discussion_r151689648
- https://github.com/nestjs/swagger/pull/2068#discussion_r1032851811
- https://github.com/nestjs/swagger/pull/1915#discussion_r960438802
- https://github.com/prisma/prisma/pull/29503#discussion_r3123027229
- https://github.com/prisma/prisma/pull/26741#discussion_r2014021926
- https://github.com/prisma/prisma/pull/26330#discussion_r1955072263
- https://github.com/prisma/prisma/pull/24645#discussion_r1654744478
- https://github.com/prisma/prisma/pull/13769#discussion_r904105445
- https://github.com/prisma/prisma/pull/13303#discussion_r871168842
- https://github.com/prisma/prisma/pull/10222#discussion_r749277779
- https://github.com/prisma/prisma/pull/10222#discussion_r749261267
- https://github.com/prisma/prisma/pull/8384#discussion_r685066776
- https://github.com/prisma/prisma/pull/8384#discussion_r680412580
