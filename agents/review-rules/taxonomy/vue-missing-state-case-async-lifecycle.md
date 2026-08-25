---
id: vue-missing-state-case-async-lifecycle
layer: vue
frameworks: ["vue@2.x", "vue@3.x", "@vue/runtime-core", "@vue/runtime-vapor"]
severity_default: HIGH
---
## 觸發訊號
diff 中新增或修改的邏輯，圍繞著「非同步解析、Suspense/KeepAlive 生命週期、hydration 匹配」這類本質上會有三種以上互斥結果的流程（例如非同步元件的 pending/resolved/rejected、hydration 分支的 valid-content/invalid-content/outer-fallback、元件的 mounted/pending-中被卸載/destroyed），但要去確認：
- 函式回傳型別是否只用一個 boolean，或用兩個 falsy 值（`undefined`/`null`）去區分兩種不同語意的狀態；
- Promise/async 鏈是否只接了成功路徑（`.then(...)`），沒有對稱地處理失敗（`.catch`/reject）或「解析中途被卸載/被切換」的清理路徑；
- 用來追蹤生命週期進度的計數器或旗標（如 `pendingId`、`deps++`/`deps--`、`suspenseId`）在這次改動中是否只往一個方向被驗證，沒有檢查另一個觸發時機（例如巢狀切換、HMR 重用、元件在 resolve 前被卸載）是否也需要同步更新；
- 快取/訂閱動作（`cache.set`、push 進某個 effects/anchors 陣列）是否假設一定會走到「resolve 成功」這條路，沒有考慮「一直沒 resolve 就被卸載」或「resolve 失敗」時該陣列要不要清掉。

## 判準
這類程式碼在正常路徑（資源順利 resolve、元件安穩掛載到卸載）下完全沒問題，但一旦進入「中途被打斷」的分支——非同步元件在 resolve 前被卸載、Suspense 在 pending 時被巢狀切換、KeepAlive 快取時機落在 Suspense resolve 之前或之後、hydration 過程中內層空片段先於外層 slot 決策完成——就會出現訂閱沒清掉、快取到尚未真正掛載的 vnode，或計數器/旗標對不上導致狀態機卡死。這些都是時序相關的邊界情況，一般測試很難覆蓋到，所以留給 code review 抓比等 production race condition 划算。另外，用 `undefined`/`null` 這兩個 falsy 值去表達兩種不同語意的狀態，會讓下游 `if (x)` 這類寫法把 pending 和 rejected 混為一談，之後有人加新分支很容易誤判。

## 嚴重度
CRITICAL：漏掉的第三態會導致記憶體洩漏（effect/訂閱沒清除）、快取到未真正掛載的 vnode，或生命週期計數器（`deps`/`pendingId`）永久卡死不歸零。
HIGH：漏掉的分支只在特定巢狀或組合情境下觸發（如巢狀 Suspense、KeepAlive 疊加 v-show、HMR 重用元件實例），一旦觸發會造成畫面錯亂，且往往會跟既有 issue 的修復互相打架（回歸舊 bug）。
MEDIUM：用兩個 falsy 值混用表達三種狀態，但目前所有呼叫端都寫對了，屬於可讀性與未來維護風險，暫時不會造成實際錯誤。

## 反例（不該報）
- 函式本來就只有兩種互斥結果（單純的 enable/disable 之類的 boolean flag），不要因為看到 `if/else` 就套用這條規則。
- 第三態已被證明不可達，且有明確論證或既有機制保證（例如已驗證 `QUEUED` flag 是唯一的去重層，`includes()` 檢查純屬多餘防禦），這種情況下不該再要求疊加防禦性程式碼。
- 純粹的型別/格式/命名修正（例如幫某個屬性加一個不符合規範的列舉值）不屬於狀態遺漏問題。

## 出處
- https://github.com/vuejs/vue/pull/4506#discussion_r92942074
- https://github.com/vuejs/vue/pull/4506#discussion_r92926540
- https://github.com/vuejs/core/pull/15172#discussion_r3687308900
- https://github.com/vuejs/core/pull/15172#discussion_r3672284169
- https://github.com/vuejs/core/pull/15027#discussion_r3499532062
- https://github.com/vuejs/core/pull/14865#discussion_r3302351750
- https://github.com/vuejs/core/pull/13355#discussion_r2095166389
- https://github.com/vuejs/core/pull/10912#discussion_r1612554027
- https://github.com/vuejs/core/pull/10912#discussion_r1612054938
- https://github.com/vuejs/core/pull/6467#discussion_r949927515
