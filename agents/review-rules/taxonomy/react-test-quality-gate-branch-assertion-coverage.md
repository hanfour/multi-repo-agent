---
id: react-test-quality-gate-branch-assertion-coverage
layer: react
frameworks: ["react@>=16", "react-dom@>=16"]
severity_default: HIGH

---
## 觸發訊號
diff 新增或修改了測試裡的條件式包裝——`@gate <flag>`、`gate(flags => ...)`、`__DEV__` 分支、`@reactVersion` 版本限定，或是 product code 中新增了依賴 feature flag／執行環境／React 版本而產生不同行為的分支——這時要去確認：每一個分支狀態是否都有對應且內容會隨分支不同而不同的斷言，而不是同一組斷言套用在所有分支上，或只挑其中一個分支寫測試就收工。具體檢查點：
- gate 條件涉及的 flag 是 true/false 兩種狀態，測試檔裡是否兩種狀態都能被執行到、且斷言值不同（若不同狀態下行為理應不同）。
- `__DEV__` 分支的斷言是否只寫在 dev 但完全略過 prod（或反過來）。
- `@reactVersion` 限定的測試，是否只覆蓋新版本、沒有為舊版本的既有行為留斷言（或反之）。
- 若 product code 的分支條件被修改（例如新增一個 flag 判斷、改變 gate 的組合邏輯），對應測試的分支斷言是否同步更新，而不是繼續沿用舊分支的預期值。

## 判準
這類問題危險在於它不會讓 CI 當下變紅——測試照樣通過，因為分支覆蓋不到的那一半路徑根本沒被斷言檢查過。React 的 CI 會用多種 flag／版本組合重跑同一份測試，如果某個組合下沒有寫斷言，那個組合未來出現的迴歸永遠不會被任何測試抓到，直到 flag rollout 到那個環境才會被使用者發現。這正是本批漏抓中最集中的一種：reviewer 在討論串裡反覆指出「這個分支沒有斷言」「這裡套用了錯的分支預期值」「dev/prod 斷言不對稱」——而不是行內某一行寫錯。

## 嚴重度
CRITICAL：分支條件是即將或正在 rollout 的 feature flag（例如 `enableXXX`），且其中一個 flag 狀態完全沒有斷言覆蓋——該狀態上線後行為跑掉不會被任何測試抓到。
HIGH：`__DEV__` 與 production 之間，或 React major version 之間的斷言不對稱（例如關鍵行為只在其中一邊被驗證），但該分支不是正在 rollout 的旗標。
MEDIUM：分支的斷言都存在，但共用同一組預期值套用到不同分支，尚未觀察到實際差異、可能只是巧合通過；或者只是分支粒度較粗，覆蓋不夠精確。

## 反例（不該報）
- diff 只是重新命名既有 gate 旗標、或搬移已經有完整雙分支斷言的測試位置，覆蓋範圍沒有變化。
- gate 條件純粹用來 skip 不支援的 renderer／環境組合（例如 `@gate !disableLegacyMode` 用來排除不相關的 legacy 模式），本身不代表兩種行為分支，不需要雙邊斷言。
- 新增的 `__DEV__` 判斷只是包住一個純粹的 console 警告訊息比對，且該警告本來就只會在 dev 出現，prod 分支確實無需斷言。
- 分支斷言值相同是因為該行為在設計上就應該在兩個分支下完全一致（例如 flag 只影響內部實作細節，不影響對外可觀察行為），且 PR 描述或 commit message 已說明這點。

## 出處
- https://github.com/react/react/pull/35999#discussion_r2953700033
- https://github.com/react/react/pull/35501#discussion_r2686618393
- https://github.com/react/react/pull/35497#discussion_r2686119533
- https://github.com/react/react/pull/28810#discussion_r1575120259
- https://github.com/react/react/pull/30206#discussion_r1665472074
- https://github.com/react/react/pull/28135#discussion_r1468808026
- https://github.com/react/react/pull/22262#discussion_r703631585
- https://github.com/react/react/pull/21857#discussion_r669072417
- https://github.com/react/react/pull/18412#discussion_r399826031
