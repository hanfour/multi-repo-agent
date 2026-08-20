---
id: react-missing-convention-parallel-case-sync
layer: react
frameworks: ["react@*"]
severity_default: HIGH
---
## 觸發訊號
當 diff 在一個「本來就有多個平行實例」的結構中新增或修改了一筆——例如：switch/if-else 的分支、列舉值、建構子要初始化的欄位清單、傳給某函式的參數表、包在 `__DEV__` 或 feature flag 之類 gate 裡的邏輯、或是某個既有清理/還原步驟（unmount、restore、cleanup）——但只在一個呼叫點/檔案/case 裡改了，要去找同一份程式碼庫裡其他「同類型的平行位置」（其他 renderer/host config 實作、其他呼叫這個建構子的地方、其他同樣需要這個 gate 的 call site、switch 裡其他相鄰的 case、其他同樣要求檔頭慣例的新檔案），確認它們是否也需要同步更新。

## 判準
這類遺漏通常不會讓程式碼在語法上或最常見路徑上壞掉，所以本地測試常常測不到——只有真正走到那個沒被同步的分支、或使用者剛好用到那個沒被初始化的欄位時才會現形。資深 reviewer 之所以會盯著這件事，是因為這類 bug 一旦上線是「悄悄擴散」的：換一個 host config 實作就漏掉某個 handler 導致呼叫 undefined、某個 unmount 路徑漏了 restore 導致 state 沒清乾淨、新檔案沒加 `@flow` header 導致整個檔案沒被型別檢查覆蓋、switch 少一個 case 導致編譯器的 alias 分析在特定型別指令上直接漏掉別名關係进而生成錯誤程式碼。這些都是「新增時很自然只改了眼前這一處，卻忘了這個模式本身是重複出現的」。

## 嚴重度
CRITICAL：遺漏會導致執行期例外、或影響正確性關鍵的分析/轉換（例如未初始化就呼叫的 handler、編譯器 alias 追蹤漏掉某個 instruction 型別而產生錯誤輸出）。
HIGH：遺漏會造成行為不一致但不會立即崩潰（例如某個平行路徑漏了既有的還原/清理邏輯導致狀態殘留、某個 call site 少了其他同類 call site 都有的 `__DEV__` gate 導致行為不一致）。
MEDIUM：遺漏屬於慣例性/工具性質，當下不會直接造成錯誤但會削弱既有保障（例如新檔案沒加 `@flow` header 導致該檔案未被型別檢查覆蓋）。

## 反例（不該報）
- 新增的分支本來就是全新、獨立的功能，程式庫裡沒有既有的平行案例可以比對，不算「該同步卻沒同步」。
- 作者已經在同一個 diff 的其他 hunk 裡同步更新了所有平行位置，只是分散在不同檔案，需要看過整個 diff 才能判斷——確認過有同步就不該報。
- 純粹的命名、風格、型別標註 nitpick，且不影響行為一致性或分析正確性的，不屬於這類。

## 出處
- https://github.com/react/react/pull/36917#discussion_r3511278174
- https://github.com/react/react/pull/34082#discussion_r2251697943
- https://github.com/react/react/pull/33150#discussion_r2078561548
- https://github.com/react/react/pull/33151#discussion_r2081999014
- https://github.com/react/react/pull/31398#discussion_r1869512819
- https://github.com/react/react/pull/31783#discussion_r1885393529
- https://github.com/react/react/pull/35795#discussion_r2812679740
- https://github.com/react/react/pull/32465#discussion_r1987922270
