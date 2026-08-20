---
id: react-shared-function-variant-branch-creep
layer: react
frameworks: ["react@*"]
severity_default: MEDIUM

---
## 觸發訊號
PR 在一個既有的共用/核心函式（例如 renderer 的 attach()、createResponseState()、console 格式化函式）裡，為了支援新的功能旗標（如 __IS_INTERNAL_MCP_BUILD__、enableFizzExternalRuntime）或新的輸入型態（如判斷 maybeMessage 是否為 ANSI 樣板字串），直接新增可選參數（xxxConfig: T | void）、新增 if (featureFlag) { ... } 分支、或把 debug-only/internal-only 函式定義直接寫在共用函式內，而不是：(a) 用編譯期旗標把該段程式碼整段排除在非目標 build 之外、或 (b) 把該變體邏輯拆成獨立的函式/呼叫路徑。

## 判準
共用函式一旦開始為每個新旗標疊加可選參數與條件分支，會導致 unrelated 的 undefined-check、參數解析邏輯全部糾纏在一起，日後任何一個變體的行為變更都可能波及其他呼叫者；debug-only/internal-only 的程式碼若沒有用編譯期旗標實際排除，會被打包進正式 build，增加 bundle size 甚至洩漏內部工具介面；把「這個輸入是不是某種特殊格式」的判斷散落插入既有的通用處理流程中，也讓函式失去單一職責，難以推理每個分支何時觸發。

## 嚴重度
CRITICAL：debug-only/internal-only 邏輯沒有被編譯期旗標排除，導致它會被打包進正式 production/使用者可見的 build。
HIGH：共用函式的參數列表因為多個功能旗標而持續增長，且對應的條件分支彼此耦合，已經有具體證據顯示某個旗標的參數解析或未定義檢查連動影響到其他旗標的行為。
MEDIUM：共用函式新增了功能旗標專屬的可選參數/分支，但語意上還算獨立、暫時不影響其他呼叫者；或是在既有通用處理流程中插入了一個新的特殊型態判斷分支。

## 反例（不該報）
共用函式原本就是為多個變體設計的公開 API，新增的參數是所有呼叫者都會用到的通用行為（不是單一功能旗標專屬）；或新增的條件分支只是既有旗標判斷的自然延伸（例如同一個 enableXxx 旗標下處理其 true/false 兩種既定情況），並未讓函式承擔新的職責。單純新增獨立的 helper function、沒有把它跟共用函式的參數/分支糾纏在一起，也不該報。

## 出處
- https://github.com/react/react/pull/33305#discussion_r2098567711
- https://github.com/react/react/pull/29873#discussion_r1642797386
- https://github.com/react/react/pull/25703#discussion_r1071564123
- https://github.com/react/react/pull/25499#discussion_r997537768
