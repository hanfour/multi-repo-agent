---
id: react-feature-flag-flip-unjustified
layer: react
frameworks: ["react@*"]
severity_default: HIGH

---
## 觸發訊號
diff 修改了 `packages/shared/ReactFeatureFlags.js` 或其 forks（`ReactFeatureFlags.www.js`、`ReactFeatureFlags.www-dynamic.js`、`ReactFeatureFlags.native-fb.js`、`ReactFeatureFlags.native-oss.js`、`ReactFeatureFlags.test-renderer.js` 等）裡某個 flag 的預設值（`false → true`、`__VARIANT__ → true/false`、`__EXPERIMENTAL__ → __NEXT_MAJOR__` 或直接常數化）、刪除/新增一個 flag、或把兩個原本隱含綁定的 flag 拆開，但只改了單一 fork 檔案，或 PR 描述與 review 討論中沒有交代對應的 production rollout 證據、跨 fork 同步狀態、以及受影響測試/`@gate` 注解的處理方式。

## 判準
Flag flip 是全域行為開關，一旦出問題會同時牽動很多路徑，難以定位且影響面廣（例如 `enableYieldingBeforePassive` flip 後拖垮 RN sync 與 Scheduler-dev build，必須緊急 revert）。沒有 production signal（如「已在 Meta production 跑過」）就把 flag 轉成 `true` 落地，等於把驗證責任丟給下游，風險很高。多個 forks（OSS/www/native-fb/test-renderer）之間若默默不同步，會讓 OSS 使用者看到的行為和內部驗證過的行為產生落差，且這種落差通常要等出包才會被發現。當一個 flag 被拆成兩個獨立 flag（如 `disableModulePatternComponents` 與 `disableLegacyContext` 曾經隱含同值）時，若既有測試/`@gate` 只更新了其中一個，測試矩陣會出現假陽性覆蓋（測試以為蓋到了某個組合，實際上沒有）。

## 嚴重度
CRITICAL：flip 會直接影響 production 行為，且沒有 rollout 證據，也沒有保留可即時關閉的 killswitch（沒有 GK/MobileConfig 之類的動態注入路徑）——出包無法快速回退。
HIGH：flip 或新增/拆分的 flag 涉及多個 forks，但只改了其中一個檔案造成 forks 之間 diverge；或依賴該 flag 的既有測試 `@gate` 注解、`require(...).flagName` 判斷式沒有同步更新。
MEDIUM：flag 語意調整/重新命名/重新編號只影響內部測試或文件，沒有 production 曝險，但仍需確認沒有下游（例如 DevTools 依賴特定數值編碼）受影響。

## 反例（不該報）
- flag 本來就是 `__EXPERIMENTAL__`／`__VARIANT__` 這類 CI 本來就會兩種分支都跑的動態值，這次只是把某個 fork 對齊到另一個既有 fork 已驗證過的值（例如「跟 test-renderer fork 保持同步，目前無實際行為影響」），不必比照 production-signal 的高標準。
- 純粹刪除已確認沒有任何呼叫點的 dead export（不涉及 flag 開關語意，是單純清理）。
- flag 保留為 `false`／維持可動態注入的形式，且 comment 已清楚說明保留原因（例如「還有 app 在 bridgeless 上跑不了新行為，靠 `.fb.js` 版本動態控制」）——這正是判準期待的做法，不該再報。

## 出處
- https://github.com/react/react/pull/37290#discussion_r3784285468
- https://github.com/react/react/pull/33788#discussion_r2206326508
- https://github.com/react/react/pull/32240#discussion_r1934758218
- https://github.com/react/react/pull/31857#discussion_r1892741539
- https://github.com/react/react/pull/30713#discussion_r1718866728
- https://github.com/react/react/pull/28647#discussion_r1543134322
- https://github.com/react/react/pull/28419#discussion_r1514386327
- https://github.com/react/react/pull/28472#discussion_r1508805942
- https://github.com/react/react/pull/28342#discussion_r1490263620
- https://github.com/react/react/pull/27830#discussion_r1485617801
- https://github.com/react/react/pull/28151#discussion_r1470248898
- https://github.com/react/react/pull/27458#discussion_r1346363686
- https://github.com/react/react/pull/26596#discussion_r1163133200
- https://github.com/react/react/pull/26323#discussion_r1126470714
- https://github.com/react/react/pull/22723#discussion_r751553695
- https://github.com/react/react/pull/21590#discussion_r642554235
- https://github.com/react/react/pull/21072#discussion_r603309864
- https://github.com/react/react/pull/20844#discussion_r578786163
- https://github.com/react/react/pull/20844#discussion_r578764715
- https://github.com/react/react/pull/19401#discussion_r465967776
- https://github.com/react/react/pull/19521#discussion_r464557527
- https://github.com/react/react/pull/19376#discussion_r455521572
- https://github.com/react/react/pull/19376#discussion_r455300779
- https://github.com/react/react/pull/18891#discussion_r423398177
- https://github.com/react/react/pull/18446#discussion_r401762100
- https://github.com/react/react/pull/18446#discussion_r401123759
- https://github.com/react/react/pull/17925#discussion_r373151581
- https://github.com/react/react/pull/15848#discussion_r293139743
- https://github.com/react/react/pull/13444#discussion_r211315097
- https://github.com/react/react/pull/13397#discussion_r210156075
- https://github.com/react/react/pull/12849#discussion_r190006971
- https://github.com/react/react/pull/12849#discussion_r189645939
