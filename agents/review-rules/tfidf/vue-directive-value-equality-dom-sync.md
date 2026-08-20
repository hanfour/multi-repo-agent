---
id: vue-directive-value-equality-dom-sync
layer: vue
frameworks: ["vue@2.x - 3.x"]
severity_default: HIGH

---
## 觸發訊號
diff 修改 `runtime-dom`/`compiler` 內的 v-model 或 v-show 相關程式（`vModel.ts`、`vShow.ts`、`model.js`、`props.ts` 的 `patchDOMProp`、`directives/show.js` 等），內容涉及用 `value`/`oldValue`/`modelValue` 做相等判斷來決定「要不要更新 DOM 狀態」（checked、selected、display、value attribute），且判斷方式是：
- 直接用 `===`/`!==` 做參考相等（reference equality）比較陣列、Set、或其他可變物件
- 用 `!!value === !!oldValue`（布林強制轉型）比較，而非真的比較值本身
- 新增/移除一段「fast path」（在完整比較 `looseEqual` 之前先用簡化條件提前 return 或提前判斷相等）
- 混用 `.includes()`／`looseIndexOf`／`looseEqual` 中的其中一種，卻沒統一套用到所有分支（number/string/其他 type）
- 針對特殊 DOM 元素（如 `<option>` fallback 到 textContent、checkbox 的 `trueValue`/`falseValue`）取值卻沒有同步調整 oldValue 的取得邏輯

## 判準
這類程式碼的本質是「用一個相等判斷來省略沒必要的 DOM 寫入」，資深 reviewer 在意的是：這個相等判斷跟使用者實際會看到的表單狀態是否真的等價。常見錯法：
1. 用參考相等比較陣列/Set — 如果呼叫端把同一個陣列原地 mutate 後再傳進來（沒建立新物件），相等判斷會誤判「沒變」而漏掉必要的 DOM 更新，使用者操作沒有反應。
2. 用 `!value === !oldValue` 判斷「有沒有從 truthy 變 falsy」，但這會把 `0`/`''`/`null`/`undefined`/`false` 全部視為同一種狀態，掩蓋掉真正需要重新渲染的 case。
3. Fast path 只覆蓋 string/number 型別，卻讓其他 type 掉進慢路徑但用了不同的相等語意（`looseEqual` vs `includes`），造成同一份程式碼對不同資料型別的「相等」定義不一致。
4. `<option>` 沒有 value attribute 時會 fallback 到 textContent，如果 oldValue 的取得方式跟這個 fallback 邏輯不同步，比較出來的 oldValue 跟畫面上實際顯示的值對不上。

## 嚴重度
CRITICAL：使用者輸入或互動（勾選 checkbox、選取 select option、輸入文字）因誤判 `value === oldValue` 而完全沒有同步到 DOM，且沒有其他途徑（如強制重新渲染）可以自行恢復，表單顯示狀態長期與實際資料不一致。

HIGH：fast path 相等判斷在特定資料型態下（可變陣列/Set 原地修改、自訂 `trueValue`/`falseValue`、`<option>` 無 value attribute）失效，導致更新被跳過或誤觸發，但使用者可透過再次互動、切換 route 或整個元件重新掛載暫時掩蓋問題。

MEDIUM：相等判斷本身正確，但寫法不一致（例如同一檔案內一半用 `!!value`、一半用 `looseEqual`，或多加一次不必要的 clone/複製），增加日後維護時誤刪關鍵比較邏輯的風險，目前尚未造成可觀察的行為差異。

## 反例（不該報）
- 對純量、不可變的 props（單純的 string/number/boolean，且呼叫端保證每次變更都會傳入全新值）使用 `===` 做嚴格相等比較是正確且刻意的最佳化，不該報。
- `computed`/`watch`/`reactive` 內部用來「避免無限遞迴走訪同一個物件」的 `seen` Set（例如 `traverse()` 的循環引用防護），這是防重入機制，不是在判斷「要不要更新 DOM」，屬於不同機制，不適用本規則。
- `ref`/`refs` 註冊陣列時用 `Array.isArray` 判斷要不要初始化新陣列（如 `registerRef`），這是型別分支邏輯而非 value/oldValue 相等判斷，不適用本規則。
- 明確加上型別守衛後才做 fast path，且該分支已有對應測試覆蓋所有會經過該分支的資料型態（例如只對確定不可變的 number 值做 fast path，其餘一律走 `looseEqual`），這種寫法是刻意的效能取捨，不該報。

## 出處
- https://github.com/vuejs/vue/pull/6220#discussion_r129539022
- https://github.com/vuejs/vue/pull/6220#discussion_r129533019
- https://github.com/vuejs/vue/pull/6213#discussion_r129706025
- https://github.com/vuejs/core/pull/10200#discussion_r1465758741
- https://github.com/vuejs/core/pull/10200#discussion_r1465385323
- https://github.com/vuejs/core/pull/10576#discussion_r1538486346
- https://github.com/vuejs/core/pull/10576#discussion_r1537115446
- https://github.com/vuejs/core/pull/10576#discussion_r1537028980
- https://github.com/vuejs/core/pull/10576#discussion_r1536984380
- https://github.com/vuejs/core/pull/10416#discussion_r1504636259
- https://github.com/vuejs/core/pull/10416#discussion_r1504489078
- https://github.com/vuejs/core/pull/8639#discussion_r1649734448
- https://github.com/vuejs/core/pull/5780#discussion_r2163482533
- https://github.com/vuejs/core/pull/2764#discussion_r538357190
- https://github.com/vuejs/core/pull/2764#discussion_r538304949
- https://github.com/vuejs/core/pull/3230#discussion_r577078707
