---
id: react-framework-semantics-strict-mode-effect-invocation
layer: react
frameworks: ["react@>=17"]
severity_default: HIGH
---
## 觸發訊號
- diff 修改了任何跟「effect 觸發時機/次數/順序」相關的函式或條件判斷（例如：`commitDoubleInvokeEffectsInDEV`、`doubleInvokeEffectsInDEV`、`recursivelyTraverseAndDoubleInvokeEffectsInDEV`、`reappearLayoutEffects`、`reconnectPassiveEffects`、`disappearLayoutEffects`、`disconnectPassiveEffect`，或任何在 mount/update hook 內直接呼叫 effect create 函式的地方，如 `mountMemo`/`mountEvent`）——要去確認新邏輯是否與 production commit phase 既有的遍歷/條件邏輯保持一致，而不是只檢查單一 flag。
- diff 在一個原本只呼叫一次的 side-effecting 函式呼叫前後，新增了「先設狀態、呼叫、再還原狀態」的 pattern（例如 `setIsStrictModeForDevtools(true); nextCreate(); setIsStrictModeForDevtools(false);`）——要去確認中間呼叫若拋出例外，還原邏輯是否被包在 `finally` 裡，否則全域狀態會卡住。
- diff 修改了決定「要不要做某動作」的模式判斷旗標（如 `isInStrictMode`、`useModernStrictMode`、`hasOffscreenVisibilityFlag`、`root.tag === LegacyRoot`）——要去確認這個旗標作用到的每一種 root type / component type（LegacyRoot、OffscreenComponent、巢狀 StrictMode boundary）分支是否都還被正確涵蓋，而不是只涵蓋修改者當下在意的那一種。
- diff 把原本由「動態讀值/執行期計算」決定的行為，改成寫死常數或簡化過的條件式（例如把讀取 build 產物版本字串判斷 `isExperimental` 改成直接 `const isExperimental = false`）——要去確認所有下游仍以動態情境為前提運作的呼叫路徑（CI workflow、其他 caller）是否也一併更新。
- diff 讓某個原本隱含必要的參數/依賴變成 optional（如新增 `?.` 或把非 null 假設拿掉）——要去確認呼叫端原本依賴「一定存在」這件事的邏輯是否也同步調整。

## 判準
這類問題不是「這行寫錯了」，而是「這裡改的東西背後牽動一整組不變量，而作者只驗證了自己觸發到的那條路徑」。React 的 effect 雙重呼叫、StrictMode 分級、root type 分支這些機制彼此耦合很深，且測試矩陣通常不會涵蓋所有 mode 組合（Legacy + StrictMode、Offscreen 可見性切換等），所以這類 regression 很容易在 CI 綠燈的情況下被合併，之後才在特定情境下才炸出來（例如「內部 landing 時 unit test 才發現 Legacy Mode 被意外打開 strict effects」）。同樣地，把動態判斷簡化成常數，是把「當下這條路徑」跟「所有依賴這個值的路徑」的耦合切斷了，但沒有人去確認耦合的另一端有沒有跟著改。

## 嚴重度
CRITICAL：影響 production 執行路徑且會造成使用者可見的資料/行為 regression、且沒有對應測試涵蓋（例如 Legacy Mode 被意外啟用 strict effects、release pipeline 因為 flag 簡化而漏發某個套件）。
HIGH：影響 effect 生命週期正確性但侷限在特定 mode 或 dev-only 情境（StrictMode double-invoke 順序錯誤、Offscreen 可見性切換沒處理好、全域狀態沒有用 finally 還原導致例外時卡死）。
MEDIUM：純 devtools/tooling 內部行為差異，不影響最終使用者可見的 render 結果（例如 console stack frame 多一層、面板顯示邏輯的邊界情境）。

## 反例（不該報）
- 修改的是純字串、CSS class 名稱、typo、不涉及 effect 時機/次數也不涉及旗標分支簡化的一般邏輯修正。
- 新增的 side effect 呼叫本身是冪等的純函式（無外部可觀察副作用、確定不會 throw），不需要 try/finally 保護。
- 拿掉的旗標分支是因為該分支在目前程式碼路徑中已被證明不可達（已被其他上層 guard 排除），且 PR 有同步更新或補上對應的迴歸測試證明行為不變。
- diff 只是把既有邏輯抽成獨立函式做 factoring，判斷條件與涵蓋範圍完全沒變（純重構、無行為差異）。

## 出處
- https://github.com/react/react/pull/37152#discussion_r3684291366
- https://github.com/react/react/pull/36456#discussion_r3303402269
- https://github.com/react/react/pull/35240#discussion_r2694164115
- https://github.com/react/react/pull/28152#discussion_r1484844116
- https://github.com/react/react/pull/28249#discussion_r1478749748
- https://github.com/react/react/pull/28122#discussion_r1476295939
- https://github.com/react/react/pull/26791#discussion_r1188816745
- https://github.com/react/react/pull/25473#discussion_r993928270
- https://github.com/react/react/pull/25203#discussion_r967886484
- https://github.com/react/react/pull/25203#discussion_r967257467
- https://github.com/react/react/pull/25203#discussion_r967170353
- https://github.com/react/react/pull/25049#discussion_r950569132
- https://github.com/react/react/pull/25049#discussion_r943635198
- https://github.com/react/react/pull/25049#discussion_r938856451
- https://github.com/react/react/pull/22680#discussion_r746039542
