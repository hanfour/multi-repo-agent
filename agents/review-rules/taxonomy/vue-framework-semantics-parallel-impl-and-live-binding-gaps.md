---
id: vue-framework-semantics-parallel-impl-and-live-binding-gaps
layer: vue
frameworks: ["vue@2.x - 3.x"]
severity_default: HIGH

---
## 觸發訊號

diff 出現以下任一種變更時，要主動去確認「沒寫出來的那部分」是否還成立：

1. **改動的程式碼在 Vue 內部有『另一套並存實作』**，例如：
   - `packages/runtime-vapor/**`、`packages/compiler-vapor/**` 底下的函式或 transform，其名稱/職責在 `packages/runtime-core`、`packages/compiler-dom` 有對應的既有實作（如 `_update()`、`transformExpression`、`needPrefix` 判斷、slot/hydration 相關的 track 函式）
   - SSR hydration 分支中，client-only 路徑與 hydrated 路徑對同一個節點/slot 做不同處理
   
   → 確認新寫法與另一份實作的行為是否**刻意**一致或**刻意**分歧，而不是預設兩者應該長得一樣。

2. **把『透過輔助函式或多重 fallback 取得的衍生值』改成『直接讀單一屬性』**，例如把 `getComponentName(options)`（內部同時檢查 `options.name` 與 `options.tag`）換成 `options.name`。
   → 確認被砍掉的來源（如匿名元件靠本地註冊 key 得到的 `tag`）在新寫法下是否仍有值可用，還是會直接變成 `undefined`。

3. **改動 setup context / instance 上暴露方法的 getter 或 closure**，在「回傳一個轉發呼叫的函式（呼叫當下才去讀 `instance.xxx`）」與「回傳當下這個值本身（存成快照）」之間切換。
   → 確認 `instance` 上那個方法/屬性在 getter 第一次被存取「之後」是否還可能被覆寫（例如 devtools 包一層、instance 重建），以及使用者是否可能提前解構並快取這個回傳值。

4. **改動 SSR hydration 中『某個 DOM anchor / insertion point 的紀錄時機』**，例如從「hydrated VNode 本身的位置」改成「hydration 完成後量測到的位置（如 `nextSibling`）」。
   → 確認在這之間，有沒有其他 patch（尤其是 VDOM 側的 patch）可能先跑一次並移除或改變原本被引用的內容。

## 判準

Vue 3 的 render/compile 管線是「一套語意、兩到三份並行實作」（VDOM ⇄ Vapor、compiler-dom ⇄ compiler-vapor、client-only ⇄ hydrated），任何一份實作單獨看都可能是「正確的程式碼」，但如果它悄悄偏離了另一份沒被察覺、也沒被文件化，最終使用者會在兩種 render mode 下看到不一致的行為，而這種不一致通常只在特定 edge case（匿名元件、reactive props 更新順序、hydration mismatch 後的修復路徑）才會暴露，PR 討論時很難靠讀單一份 diff 發現。

同樣地，「取得衍生值改用單一屬性」和「getter 從轉發呼叫改成快照」這兩類改動，表面上是簡化，但通常是在拿掉一個為了覆蓋 edge case 而存在的間接層——原作者當初繞這一圈往往有特定原因（匿名元件沒有 `name` 但有 `tag`；`instance.emit` 可能在 setup 執行後才被覆寫），資深 reviewer 看到這種「從間接變直接」的簡化，反射動作是去問「被拿掉的那條路徑還有人在用嗎」，而不是照著新程式碼本身判斷對錯。

## 嚴重度

CRITICAL：分歧或快照時機錯誤會導致實際 DOM 結果錯誤或使用者可觀察到的功能性 bug（例如 hydration 之後節點被誤刪、覆寫後的方法沒被呼叫到、遺失的 fallback 造成執行期抓不到元件），且沒有對應測試能攔截。

HIGH：分歧發生在 VDOM 與 Vapor（或 compiler-dom 與 compiler-vapor）之間，但影響範圍侷限在特定情境（例如某種 constant-folding 判斷、某個 CE 更新時序），會造成兩種 render mode 行為不一致，但短期內不會直接產生可見錯誤。

MEDIUM：改動雖然拿掉了間接層或改變了取值時機，但相關情境目前程式庫內或可預見的使用方式下不會被觸發（例如該 fallback 分支在目前所有呼叫點都用不到）。

## 反例（不該報）

- diff 中的分歧本身**已經在 PR 描述或程式碼註解中說明是刻意行為**，且說明有具體理由（例如「Vapor CE 走 reactive props + scheduler，不走 root-only `_update()`，這是設計差異」），reviewer 只需要確認這個理由合理，不需要再要求兩邊行為一致。
- 從「輔助函式」改成「直接屬性存取」，但該輔助函式本來就只是單一屬性的別名，沒有 fallback 或多來源邏輯——這種簡化沒有語意流失，不算本規則範圍。
- getter 從轉發 closure 改成直接回傳值，但該屬性在整個生命週期內保證只被賦值一次、且賦值一定發生在 getter 第一次被存取之前——此時快照與轉發等價，不構成風險。
- hydration anchor 紀錄時機改變，但該節點路徑上沒有任何後續 patch 會移動或刪除相關 DOM（例如節點不在任何條件渲染/v-for 底下），此時提前或延後量測位置的結果相同。

## 出處

- https://github.com/vuejs/vue/pull/6985#discussion_r148434104
- https://github.com/vuejs/core/pull/15195#discussion_r3700830765
- https://github.com/vuejs/core/pull/14913#discussion_r3353010732
- https://github.com/vuejs/core/pull/14899#discussion_r3332852500
- https://github.com/vuejs/core/pull/14755#discussion_r3141517618
- https://github.com/vuejs/core/pull/5131#discussion_r789421392
