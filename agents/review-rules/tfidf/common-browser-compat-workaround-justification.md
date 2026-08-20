---
id: common-browser-compat-workaround-justification
layer: common
frameworks: []
severity_default: MEDIUM
---
## 觸發訊號
diff 中新增或修改了瀏覽器/環境相容性 workaround：UA sniffing（如 `navigator.userAgent.match(/Firefox/)`）、feature-detection 分支（`isEventSupported`、`if (!win.getSelection)`、`elementsPanel.createSidebarPane` 存在性檢查）、事件名稱 polyfill 鏈（`wheel` → `mousewheel` → `DOMMouseScroll`）、`ownerDocument`/`defaultView` 回退鏈，或針對特定瀏覽器（Firefox/Safari/IE）留下的註解式假設（如「TODO: Does Firefox support X?」「possibly Firefox」）。同類也包含依賴外部套件版本號的相容性假設（如 `package.json` 用 `>=` 而非 `~` 引入非預期 major 版本）。

## 判準
瀏覽器相容 workaround 的成本不是寫下去那一刻的成本，而是幾年後沒人敢刪的成本——一旦寫了 UA 判斷或 feature-detect 分支且沒有明確的「何時可以移除」依據（目標瀏覽器版本、ESR 支援線、caniuse 連結），它會永久卡在程式碼裡，因為沒人知道現在能不能安全刪除。同樣，過度寬鬆的版本範圍（`>=` vs `~`）在依賴安裝時可能靜默跨過 major 版本引入不相容變更，這類「相容性」修改本身反而製造了不相容風險。resigant reviewer 在這類 diff 上真正檢查的是：這個 workaround 有沒有具體的目標依據（不是「以防萬一」），以及是否已用可查證的來源（MDN 相容表、caniuse、實測）取代臆測或過時假設。

## 嚴重度
CRITICAL：相容性判斷錯誤會直接導致功能在目標瀏覽器上壞掉或行為不可預期（例如誤判某瀏覽器不支援某 API 而完全跳過必要邏輯），且沒有測試或人工驗證覆蓋。
HIGH：新增 UA sniffing 或 feature-detect 分支缺乏任何依據來源（無註解引用相容表/caniuse/實測結果），純粹基於臆測或「以防萬一」；或依賴版本範圍寫成過寬（`>=`）而非語意化鎖定（`~`/`^`），有引入非預期 breaking change 的風險。
MEDIUM：workaround 本身合理但缺少「何時可移除」的線索（如目標版本號、ESR 支援線），導致技術債無法追蹤；或註解留有未解決的 TODO/疑問（如「Does Firefox support X?」）卻未實際查證就合併。

## 反例（不該報）
- Workaround 已附上明確依據並清楚寫出可移除條件（例如「Firefox 17+ 支援 wheel，我們最低支援 ESR 52.5，故可安全移除舊分支」），即使保留該分支也不該報——這是有意識的防禦性保留，不是臆測。
- 為未來可能的發布平台（如尚未支援但規劃中的 Safari 版本）預留 feature-detect 檢查，且註解清楚說明保留原因（而非遺留未清理的舊碼），屬合理設計決策。
- 單純的程式碼整理（如修正註解錯字、拆分過長變數宣告）而未改變任何相容性判斷邏輯本身。
- 移除已證實不再需要的 workaround（附測試或平台文件佐證），這是修正方向，不該報。

## 出處
- https://github.com/react/react/pull/35240#discussion_r2693968254
- https://github.com/react/react/pull/33354#discussion_r2107409824
- https://github.com/react/react/pull/30340#discussion_r1678402569
- https://github.com/react/react/pull/28412#discussion_r1498355334
- https://github.com/react/react/pull/26539#discussion_r1157426175
- https://github.com/react/react/pull/15687#discussion_r286203326
- https://github.com/react/react/pull/15036#discussion_r263019817
- https://github.com/react/react/pull/12037#discussion_r203227299
- https://github.com/react/react/pull/11594#discussion_r151866980
- https://github.com/react/react/pull/11178#discussion_r143985409
- https://github.com/react/react/pull/59#discussion_r4535811
