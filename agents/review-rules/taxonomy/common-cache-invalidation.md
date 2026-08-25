---
id: common-cache-invalidation
layer: common
frameworks: ["*"]
severity_default: CRITICAL
---
## 觸發訊號

- diff 對某個既有的 memoization / cache 站點（`Map`、`WeakMap`、`x.cache ??= ...`、`getXxxLinks(...).resolvedYyy`、`instantiations.get/set`、`.buildinfo` / structureReused 判斷等）新增了一個會影響輸出結果的參數、flag、或狀態（例如新的 option、新的 mode、新的展開深度、新的 context）。
- diff 在某段程式碼中就地修改（mutate）一個物件（symbol、node、type、config、exports）的欄位，而同一個 diff 或既有程式碼中，別處已經對這個物件（或依賴它的衍生值）做過快取讀取/寫入。
- diff 新增或修改了「判斷是否可以重用既有結果」的邏輯（up-to-date 檢查、`structureReused`、`hasInvalidatedResolution`、watcher 觸發範圍），但只比對了部分決定輸出正確性的欄位（例如只比對 config path 沒比對 file set，只比對部分 compiler options）。
- diff 在某段流程中暫時調整/覆寫某個共享狀態（antecedent、label、labels、временный context）去跑一段計算，然後把狀態還原——同時這段計算路徑上原本會寫入快取。
- diff 新增一個會影響模組解析/建置正確性的外部輸入來源（package.json 欄位、新檔案、被刪除的檔案、peer dependency），但沒有同步在對應的 cache key 或 watcher 清單中加入它。

## 判準

這類問題的核心是「快取的正確性依賴一組隱含的輸入集合，而這組集合被 diff 悄悄擴大了，快取邏輯卻沒有跟著擴大」。表現形式通常是：
- Cache key 少算了一個真正會影響結果的維度，導致同一把 key 對應到不同的正確答案，第二次查表拿到的是第一次的舊值。
- 某段程式碼寫入快取時，讀到的是尚未定案（暫時性、推測性）的中間狀態，之後產生的「正確」結果反而永遠讀不到，因為快取已經被污染。
- 某個物件被程式改了之後，先前基於舊狀態算出並存起來的衍生值沒有被清掉，後續讀者拿到過期資料且完全不會出錯（silent wrong answer，不是 crash）。
- Invalidation / up-to-date 判斷只看了子集欄位，遺漏的欄位剛好是這次改動新引入或本來就存在但沒人注意到的。

這類 bug 難以用單元測試自然覆蓋（需要特定的多步驟情境、特定的 scope/context 疊加順序），且錯誤結果通常「看起來正常」，只在特定重用路徑下才會爆出來，因此對 reviewer 而言必須主動去讀 diff 以外的呼叫路徑，而不能只看被改動的那幾行。

## 嚴重度
CRITICAL：快取住的是型別檢查 / 語意分析 / 建置產物是否需要重新編譯的判斷（如 program structureReused、buildinfo、type instantiation cache），一旦命中舊值會讓編譯器/建置系統回報錯誤的成功或錯誤的診斷，且使用者無感知、無法自行繞開。

HIGH：快取住的是查找結果（module resolution、symbol exports、properties），命中舊值會讓某些使用情境下功能行為錯誤（例如自動匯入建議錯誤、跳轉定義錯誤），但範圍侷限在特定功能而非整體正確性判斷。

MEDIUM：cache key 遺漏的維度只在極端/degenerate 情境下才會造成錯誤結果，或是 invalidation 邏輯過度保守（多失效、犧牲效能但不影響正確性）。

## 反例（不該報）

- Diff 新增的參數本身不影響被快取函式的回傳值（例如只是額外的 diagnostic/trace 參數），因此不需要進 cache key。
- 快取的物件在整個生命週期內是不可變的（immutable/frozen），或每次都是新建立的實例（不會被就地修改），因此沒有「舊值殘留」的風險。
- Diff 移除或重構了 cache，但同時也移除了對應的讀取路徑，不存在新舊資料不一致的窗口。
- 被標記為「暫時性/推測性」的計算本來就明確標示 `noCacheCheck` / 有意跳過快取，且沒有任何路徑會意外把這次結果寫回主快取。
- 該處雖有快取但是純效能優化（miss 只是重算一次，不會回傳錯誤答案），reviewer 討論的是快取鍵長度/效能微調而非正確性。

## 出處
- https://github.com/microsoft/TypeScript/pull/61492#discussion_r2037999228
- https://github.com/microsoft/TypeScript/pull/61265#discussion_r1969868929
- https://github.com/microsoft/TypeScript/pull/60754#discussion_r1884360689
- https://github.com/microsoft/TypeScript/pull/59972#discussion_r1760009231
- https://github.com/microsoft/TypeScript/pull/55695#discussion_r1320710471
- https://github.com/microsoft/TypeScript/pull/55695#discussion_r1320657223
- https://github.com/microsoft/TypeScript/pull/53873#discussion_r1169135617
- https://github.com/microsoft/TypeScript/pull/53771#discussion_r1167012907
- https://github.com/microsoft/TypeScript/pull/53034#discussion_r1130050633
- https://github.com/microsoft/TypeScript/pull/53034#discussion_r1125108228
- https://github.com/microsoft/TypeScript/pull/54944#discussion_r1325042193
- https://github.com/microsoft/TypeScript/pull/50974#discussion_r981706113
- https://github.com/microsoft/TypeScript/pull/50776#discussion_r978178171
- https://github.com/microsoft/TypeScript/pull/50776#discussion_r978148165
- https://github.com/microsoft/TypeScript/pull/50776#discussion_r978143284
- https://github.com/microsoft/TypeScript/pull/49275#discussion_r883764809
- https://github.com/microsoft/TypeScript/pull/49275#discussion_r883763394
- https://github.com/microsoft/TypeScript/pull/44935#discussion_r829488158
- https://github.com/microsoft/TypeScript/pull/57029#discussion_r1498404307
