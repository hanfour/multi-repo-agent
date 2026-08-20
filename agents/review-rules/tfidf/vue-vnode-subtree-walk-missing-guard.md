---
id: vue-vnode-subtree-walk-missing-guard
layer: vue
frameworks: ["vue@^3"]
severity_default: HIGH
---
## 觸發訊號
diff 中出現迴圈或遞迴沿著 `vnode.component.subTree`（或 `vnode.component` / `vnode.el` / `vnode.placeholder` 相關鏈）往下鑽取實際 DOM 節點的邏輯，尤其是：
- 用 `while (current.component) { current = current.component.subTree }` 這類迴圈往下鑽子元件的 subTree，最終回傳 `current.el` 或 `current.placeholder`，卻沒有在找到目標（如 Suspense placeholder、Teleport anchor）時就地提前 return，而是繼續往下鑽到底層。
- 在 async component wrapper 或 HOC 更新（如 `updateHOCHostEl`）時，把 `placeholder` / `el` 從子層 subTree 複製到父層 vnode，卻沒有在對應的清除時機（Suspense resolve、component unmount）同步清掉，導致 vnode 持有已從 DOM 移除的節點參照。
- 判斷「是否為未解析的 async component / 特殊包裝」的條件式，只覆蓋了一種既有情境（例如 `isAsyncWrapper(vnode) && !vnode.type.__asyncResolved`），沒有涵蓋等價的另一種情境（例如 `component.asyncDep && !component.asyncResolved`），導致該分支在特定組合下不會被觸發。

## 判準
沿 vnode/component 樹往下鑽取真實 DOM 節點的程式碼，任何遺漏的停止條件都會產生兩類後果：(1) 拿到錯誤的節點（撈到孫層而非目標層的 placeholder/anchor，導致定位錯誤或 SSR/hydration mismatch），(2) 節點參照沒被正確清除而變成 memory leak（引用已從 DOM 移除的 detached node）。這類 bug 難以被單元測試覆蓋，因為只有在特定組合（Suspense + 巢狀 HOC、async component + Teleport range 之類）下才會觸發；reviewer 通常是靠讀程式碼推理邊界情境才發現，而不是跑出失敗案例才抓到，所以在 review 階段主動比對「這個迴圈/條件是否窮舉了所有已知的包裝型態、以及清除時機是否對稱」特別有價值。

## 嚴重度
CRITICAL：走訪結果被用於後續 DOM 操作的錨點（insertBefore/removeChild/patch），遺漏會直接造成節點插入到錯誤位置、丟出例外，或已卸載元件持續佔用記憶體（明確可驗證的 memory leak）。
HIGH：遺漏只在特定巢狀情境（HOC 包裝 async component、Suspense 內的 Teleport range）下才觸發，是正確性問題但不會在多數路徑上立即造成使用者可見錯誤。
MEDIUM：遺漏的分支只影響非關鍵路徑（例如僅影響 dev-only mismatch 檢查是否觸發，不影響實際 render 結果）。

## 反例（不該報）
- 遍歷邏輯已在每一層迭代前有明確的提前 return/break，且終止條件已涵蓋所有已知的包裝型態（component/Fragment/Teleport/Suspense），不必因為「理論上還可能有其他型態」就要求加更多分支。
- 純粹把 `if/else if` 鏈改寫成一連串獨立 `if` return（無邏輯差異的重構），沒有改變走訪深度或停止條件。
- 程式碼只是單純讀取 `vnode.el`，不涉及往下鑽取子元件 subTree，也不涉及需要跨階段清除的暫存欄位（如 placeholder）。

## 出處
- https://github.com/vuejs/core/pull/14177#discussion_r2600841380
- https://github.com/vuejs/core/pull/14177#discussion_r2600833876
- https://github.com/vuejs/core/pull/14177#discussion_r2596835886
- https://github.com/vuejs/core/pull/14177#discussion_r2596826835
- https://github.com/vuejs/core/pull/15035#discussion_r3510007504
