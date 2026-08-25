---
id: vue-cache-invalidation-stale-capture
layer: vue
frameworks: ["vue@3.x"]
severity_default: CRITICAL
---
## 觸發訊號
diff 出現下列任一種「先算/先存，之後才用」的模式時，要回頭確認來源是否可能在存取與使用之間變化，以及變化時有沒有對應的失效/重新讀取機制：

1. 新增或修改一個快取/記憶化結構（Map、WeakMap、物件上的快取欄位、閉包變數）用來存放「算過一次就重複使用」的結果 — 確認快取的 key 是否涵蓋所有會影響該結果的輸入（例如編譯選項、props、當前 scope），而不是只涵蓋部分輸入。
2. 把一個原本透過 getter/computed 動態讀取來源的存取方式，改成在某個時間點讀一次就存成固定值（例如 `get x() { return src.x }` → `x: src.x`）— 確認 `src.x` 之後若改變，這個固定欄位有沒有被同步更新，或有沒有證據（compiled 場景、interop 契約）保證 `src.x` 之後不會再變。
3. 在 hydration / patch 過程中捕捉一個 DOM 節點或 anchor 參照，並在後續的非同步、排程或另一輪 patch 步驟中才使用它 — 確認捕捉與使用之間是否有其他 patch、卸載、SSR 內容替換等動作可能已經移除或取代掉這個節點，導致參照失效。
4. 把回呼/job 放入排程佇列（`queueJob`、`queuePostFlushCb`、microtask、`.then()` chain）並綁定某個 component instance 或 effect scope — 確認該 instance/scope 若在 job 執行前被卸載或 dispose，有沒有對應的 invalidate/移除路徑，而不是任由過期 job 繼續執行。
5. 在非同步流程尚未完成前就讀取一個要等該流程 resolve 之後才會填值的屬性（例如 async `setup()` 尚未 resolve 前就讀 `instance.sp`）— 確認是否該在非同步完成之後才重新讀取，而不是提前讀到暫時性的 `null`/舊值。

## 判準
這類問題的共同結構是：某個值被「捕捉」或「快取」在某個時間點，但它真正的來源（DOM 樹、instance 生命週期、非同步 setup、compile 選項）在捕捉之後仍可能改變。因為觸發條件通常是特定時序窗口（unmount 恰好卡在 job 執行前、hydration 後緊接著一次 VDOM patch、async setup 還沒 resolve 就有人讀取），單元測試很容易只覆蓋「沒有時序競爭」的路徑而放過這類 bug；等到進了 production 才會在真實使用者互動節奏下觸發，而且往往表現為「畫面跟資料對不上」「幽靈 DOM 節點」「卸載後仍然執行的 side effect」這種難以定位的症狀。Vue runtime 為了效能大量使用一次性計算 + 重用的模式，這正是這類遺漏最容易藏身的地方。

## 嚴重度
CRITICAL：快取/捕捉的是 DOM 結構、hydration anchor 或元件生命週期相關狀態，一旦沒有失效機制會導致實際 DOM 內容與資料狀態不同步、hydration mismatch 沒被清理、或已卸載元件的 job 仍然執行（可能造成 crash 或記憶體洩漏）。
HIGH：快取 key 遺漏了會影響結果的輸入，導致不同情境（如不同 compile options）誤用同一份快取結果，但不直接造成 DOM 不一致或崩潰。
MEDIUM：不一致只出現在 dev-only 分支、警告訊息或非關鍵路徑，不影響最終渲染結果的正確性。

## 反例（不該報）
- 被捕捉/快取的來源在該 scope 內本質上不可變（一次建構後不再變化），沒有失效需求。
- 該處是刻意的快照語意，且有明確理由（例如刻意對齊既有 VDOM 行為、鎖定測試快照），不是遺漏。
- 把 getter 改成 plain property 時，若有 compiled 場景或既有 interop 契約可以佐證該來源之後不會再變，且沒有可重現的 compiled regression 支持「會變」的假設，不該報——只有在能舉出具體、可重現的來源變化路徑時才報。

## 出處
- https://github.com/vuejs/core/pull/14999#discussion_r3456815864
- https://github.com/vuejs/core/pull/14899#discussion_r3332852500
- https://github.com/vuejs/core/pull/14755#discussion_r3141517618
- https://github.com/vuejs/core/pull/14730#discussion_r3107836491
- https://github.com/vuejs/core/pull/14695#discussion_r3056190241
- https://github.com/vuejs/core/pull/10893#discussion_r1722561238
- https://github.com/vuejs/core/pull/9370#discussion_r1353120528
- https://github.com/vuejs/core/pull/9370#discussion_r1352464776
- https://github.com/vuejs/core/pull/4631#discussion_r713266689
- https://github.com/vuejs/core/pull/3070#discussion_r569369269
- https://github.com/vuejs/core/pull/717#discussion_r377964441
