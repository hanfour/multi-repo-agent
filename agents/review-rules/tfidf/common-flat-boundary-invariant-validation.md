---
id: common-flat-boundary-invariant-validation
layer: common
frameworks: ["typescript@*"]
severity_default: HIGH
---

## 觸發訊號
Diff 新增或修改「flat/serialized 外部形狀 → 內部結構化型別」的轉換函式（例如 `xxxFromFlat`、`xxxFromSerialized`、`indexInputFromSerialized`，或組裝該型別的 test fixture builder），且符合下列任一情況：
- 外部/序列化型別把彼此有關聯的欄位各自標成獨立 optional（例如 `columns?`/`expression?` 這種本應互斥的 XOR 關係、或 `prefix?` 是否存在代表某種命名模式），轉換函式只是把欄位原封不動搬過去，沒有重新檢查兩者的一致性；
- 轉換或 fixture 組裝物件時，對某個本該透傳的欄位直接寫死常數（如 `withCheck: undefined`），而不是取自來源物件（如 `withCheck: policy.withCheck`）。

## 判準
內部結構化型別（union、XOR 欄位、naming 規則）依賴某個不變量成立才能被下游安全使用；這個不變量若只在建構子裡檢查過一次，任何「flat → structured」的轉換點都必須重新驗證，否則不受信任的外部輸入（contract.json、DB 讀出、API payload）可以繞過建構子的保護，產生看似合法、實際矛盾的物件（例如同時有 `columns` 又有 `expression`，或 `prefix` 與 `name` 對不上）。同理，test fixture 對某欄位寫死常數而非透傳來源值，等於永遠不測試該欄位的實際邏輯——這種缺陷不可見，直到有人依賴那個欄位時才會發現壞掉的邏輯早已沒被測到。

## 嚴重度
CRITICAL：驗證繞過會在執行期構造出邏輯矛盾的物件（XOR 兩側同時成立或同時缺席），且該物件會被下游直接當合法輸入使用（寫入 DB、產生 migration、影響 production 行為）。
HIGH：轉換函式對本該互斥或彼此依賴的欄位只做了部分檢查（只驗證其中一側），或同一個不變量在多個轉換點各自重複實作，容易漏改其中一處。
MEDIUM：test fixture 對非核心欄位寫死常數而非透傳，目前沒有現有測試依賴該欄位，影響侷限於測試盲點本身、尚未造成生產風險。

## 反例（不該報）
- 轉換函式的目標型別本身沒有互斥或關聯欄位（單純扁平映射，沒有不變量需要維護）。
- 內部型別純粹是資料傳遞用的 DTO，下游不會對其做結構性假設或邏輯分支。
- fixture 寫死的欄位正是該測試刻意要固定住的驗證目標值，而非「順手忽略」。
- 轉換函式在同一個呼叫路徑上已有明確的不變量檢查（例如驗證失敗即拋錯/回傳 `undefined` 並在上層處理），只是實作風格不同。

## 出處
- https://github.com/prisma/prisma/pull/29808#discussion_r3685062984
- https://github.com/prisma/prisma/pull/29808#discussion_r3685062270
- https://github.com/prisma/prisma/pull/29808#discussion_r3685059861
- https://github.com/prisma/prisma/pull/29808#discussion_r3683519194
- https://github.com/prisma/prisma/pull/29807#discussion_r3682734547
