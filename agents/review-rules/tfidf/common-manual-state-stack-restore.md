---
id: common-manual-state-stack-restore
layer: common
frameworks: ["*"]
severity_default: HIGH
---
## 觸發訊號
diff 中出現手動 save/restore 一份可變的共享狀態（module-level 變數、closure 變數、或遞迴函式間共用的欄位)，典型長相：
- `const save = x; x = newValue; ...(recurse/callback)...; x = save;`
- 把上述模式改寫成用陣列/Map 當 stack 做 `push`/`pop`（例如 reserved-names stack、speculation reset stack）
- 把遞迴函式改寫成用手動 stack 陣列做迭代（避免 call stack overhead），但 stack 內容是物件/tuple 而非純量
- 新增/修改一個「進入時記錄一個 flag、離開前重置該 flag」的旗標（例如 `isIntersectionConstituent` 這類遞迴傳遞的 boolean 狀態）
- 為了效能把 save/restore 狀態從物件配置改成 bitmask 或字串 key（cache key 組裝）

## 判準
這類手動 save/restore 或 stack 管理程式碼在 review 時特別容易出兩種問題：
1. **不平衡風險**：push 與 pop（或 save 與 restore）沒有用 `try/finally` 保護，一旦中間的 callback/recurse 拋例外或提前 return，狀態就卡住，後續呼叫全部讀到髒狀態，而且這種 bug 通常沒有測試會抓到，因為只有在例外路徑才會觸發。
2. **語意漂移風險**：這類旗標/狀態常常「傳播貫穿所有呼叫，但在特定時機被重置」（如 `isIntersectionConstituent` 在每次 `isRelatedTo` 呼叫時被重置，但 `isApparentIntersectionConstituent` 是用來防止重置的參數）——這種規則非常隱晦，review 時必須確認新寫法有沒有悄悄改變「誰會重置、誰不會」的邊界，否則型別檢查等邏輯會靜默算錯。
3. **效能面**：這些 stack 常位在 parser/checker/emitter 的熱路徑，每次 push 都配置新物件（tuple、`SpeculationReset` 物件）比用純量陣列平行維護（parallel arrays）或 bitmask 明顯更貴；reviewer 對此類 PR 的常見意見是「能不能不要配置物件」「能不能從尾端提早 bail out 而不是每次都掃整個 stack」。

## 嚴重度
CRITICAL：state 沒有正確平衡且會靜默影響型別檢查/語意判斷的正確性（例如遞迴旗標重置時機錯誤，導致某些型別關係被錯誤判定為相容/不相容，且沒有崩潰也沒有測試訊號）。
HIGH：save/restore 沒有用 `try/finally`（或等價機制）保護，callback 拋例外時全域/共享狀態不會被還原，污染後續所有呼叫。
MEDIUM：邏輯正確且有適當還原保護，但在明確的熱路徑（parser/emitter 每個節點都會跑到）中每次呼叫都配置新物件/陣列，或用字串拼接組 cache key，而非用純量/bitmask 等更輕量的作法。

## 反例（不該報）
- 純區域變數的 save/restore，且不會被遞迴呼叫或例外路徑穿越（沒有跨函式共享，也沒有 callback 中斷的機會）——這種本來就不需要 try/finally。
- 已經用 `try/finally` 正確包住的 save/restore，且 push/pop 明顯配對（例如透過同一個 helper 函式進出）。
- 發生在初始化/一次性冷路徑（非每節點都會執行）的 stack 配置，效能影響可忽略。
- 把遞迴改寫成顯式 stack 迭代，但 stack 內容本身就需要攜帶多個關聯值（無法簡化成純量），且已有測試覆蓋各種提前返回路徑。

## 出處
- https://github.com/microsoft/TypeScript/pull/58418#discussion_r1588556311
- https://github.com/microsoft/TypeScript/pull/56395#discussion_r1393376672
- https://github.com/microsoft/TypeScript/pull/55224#discussion_r1281186638
- https://github.com/microsoft/TypeScript/pull/52382#discussion_r1087093294
- https://github.com/microsoft/TypeScript/pull/52382#discussion_r1085757200
- https://github.com/microsoft/TypeScript/pull/45578#discussion_r696191190
- https://github.com/microsoft/TypeScript/pull/36248#discussion_r368196417
- https://github.com/microsoft/TypeScript/pull/27627#discussion_r224307618
- https://github.com/microsoft/TypeScript/pull/19158#discussion_r150333626
