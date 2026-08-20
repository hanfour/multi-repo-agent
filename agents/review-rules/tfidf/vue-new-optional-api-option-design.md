---
id: vue-new-optional-api-option-design
layer: vue
frameworks: ["vue@3.x"]
severity_default: MEDIUM
---
## 觸發訊號
diff 對外部（或跨套件）interface/type 或 function signature 新增一個 optional 欄位或參數，尤其是：
- boolean flag（如 `vapor?: boolean`、`preserveTilde?: boolean`、`customElement?: boolean | ((filename: string) => boolean)`）
- 使用者可傳入的 callback/strategy（如 async component 的 `hydrateStrategy`、`getFallthroughAttrs?: (attrs: Data) => Data | undefined`）
- 附加識別/去重用的內部欄位（如 `__formater_key` 這類 devtools formatter 標記）

且該欄位是為了讓呼叫端「額外告知」一個在框架內部其實可以推導、或已經在別處存在等價資訊的狀態。

## 判準
新增的 optional 參數會永久增加公開 API 表面與維護成本，資深 reviewer 會追問：
1. 這個值是否本來就能在呼叫鏈內部算出來（例如 compiler 在編譯當下已經知道是不是 vapor component），此時再要求呼叫端手動傳入會產生兩份真相來源，未來容易漂移不同步。
2. 因為是 optional，編譯器/型別系統不會強制既有呼叫點更新，容易漏改（如 `getFallthroughAttrs` 因為是 optional 導致 `server-renderer` 的呼叫點沒跟著更新，行為悄悄退化)。
3. boolean 型別是否太粗糙、命名是否精確表達語意（`vapor` vs 更明確用途、`preserveTilde` 是否比泛用命名更不會誤導）。
4. 若新選項是使用者可自訂的 callback/strategy，框架與使用者之間「例外/錯誤誰負責處理」是否講清楚——沒講清楚會出現靜默失敗（如 hydrate 永遠不會發生卻無錯誤）。
5. 若該狀態需要跨多個模組/多版本共存（如同頁多版 Vue 各自的 devtools formatter），單純加一個新旗標而不考慮版本化/去重，之後會需要重新設計。

## 嚴重度
CRITICAL：新 optional 參數若在既有呼叫點被遺漏，會造成正確性錯誤且沒有任何編譯期或執行期報錯（純靜默行為退化，如 fallthrough attrs 漏傳）。
HIGH：新增的旗標/callback 明顯可由既有 context 推導卻仍要呼叫端手動同步傳入，或使用者自訂 strategy 出錯時的責任歸屬完全未定義（導致功能永久失效且無提示）。
MEDIUM：命名不夠精確可能誤導、boolean 型別是否過粗尚待討論、或去重/版本化等邊界情境未涵蓋但影響範圍有限。

## 反例（不該報）
- 新增的 optional 欄位只在單一內部模組內使用、外部呼叫點完全不受影響，或本來就是唯一合理值來源（無法由既有 context 推導）。
- PR 作者已對所有既有呼叫點做過完整 audit 並同步更新，且對 boolean vs 更嚴謹型別、命名精確度都有明確 rationale 並經 reviewer 確認可接受。
- 新增的是 required 參數（非 optional），不存在「呼叫點被悄悄遺漏」的風險。
- 純測試檔案內新增的輔助欄位/mock，不涉及公開 API 表面。

## 出處
- https://github.com/vuejs/vue/pull/3030#discussion_r65758247
- https://github.com/vuejs/core/pull/13630#discussion_r2443889075
- https://github.com/vuejs/core/pull/13630#discussion_r2438556912
- https://github.com/vuejs/core/pull/13462#discussion_r2354262518
- https://github.com/vuejs/core/pull/12311#discussion_r1828599042
- https://github.com/vuejs/core/pull/12311#discussion_r1827125566
- https://github.com/vuejs/core/pull/11458#discussion_r1697057678
- https://github.com/vuejs/core/pull/11458#discussion_r1697049802
- https://github.com/vuejs/core/pull/11458#discussion_r1696671291
- https://github.com/vuejs/core/pull/10472#discussion_r1522917815
- https://github.com/vuejs/core/pull/10472#discussion_r1522872138
- https://github.com/vuejs/core/pull/10472#discussion_r1522785966
- https://github.com/vuejs/core/pull/8989#discussion_r1301123490
- https://github.com/vuejs/core/pull/8989#discussion_r1301118285
- https://github.com/vuejs/core/pull/930#discussion_r404826529
