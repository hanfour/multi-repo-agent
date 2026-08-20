---
id: common-flaky-test-retry-masking
layer: common
frameworks: ["jest@*"]
severity_default: MEDIUM
---
## 觸發訊號
diff 中出現用固定次數重試/重複執行來讓測試通過、而不是修掉底層問題的邏輯，例如：
- 新增或修改 `retries: { times: N }`（或類似的重試設定）包住一段等待非同步狀態的斷言
- 新增 `testRepeat(n)` 之類的 wrapper，把同一個測試包裝執行多次才視為通過
- commit message、PR 描述或行內註解出現「flaky」「run it N times locally」「busts flakiness」等字眼
- 硬編碼的大數字重試/重複次數（例如 10、350+）卻沒有說明背後的競態條件是什麼

## 判準
重試/重複執行是把 flaky test 的根因（競態條件、非同步時序、外部依賴不穩定）用統計方式蓋掉，而不是修掉。這種 hack 通常伴隨三個副作用：CI 時間拉長、測試意圖被稀釋（reviewer 看不出真正在驗證什麼行為）、以及這段「terrible logic」會被複製貼上到其他測試檔而擴散。作者自己承認邏輯很爛（如「Terrible logic, but is mostly for tests」）本身就是要求根因修復而非合併掩蓋的訊號。

## 嚴重度
CRITICAL：用重試/重複掩蓋的 flaky 邏輯出現在生產程式碼路徑（非測試檔），且直接影響對外行為或資料正確性的判斷（例如靠 retry 蓋掉會導致資料不一致的 race condition）。
HIGH：重試次數異常大（例如 >50 次）或沒有逾時上限／backoff，可能顯著拖慢 CI，且沒有對應 issue/TODO 追蹤根因。
MEDIUM：測試檔案內加入固定次數重試或 repeat wrapper 壓制已知的 flaky 測試，但沒有留下可追蹤的根因說明或後續修復計畫。

## 反例（不該報）
- 對外部服務／網路呼叫使用有限次數＋backoff 的重試，且該測試本來就是要驗證「重試機制本身」的正確性（測試對象就是 retry 邏輯）。
- 效能測試／壓力測試刻意重複執行以取得統計分布（例如量測 timing、找 memory leak），且 PR 已寫明目的，不是拿來掩蓋斷言失敗。
- 重試邏輯附有對應 issue 連結、TODO 或註解說明根因與未來移除條件，屬於已追蹤、有時效性的技術債，而非靜默掩蓋。
- 測試框架內建、範圍受限且有文件記錄的重試機制（如針對已知不穩定的第三方 API），且未被用來掩蓋自身程式碼的競態條件。

## 出處
- https://github.com/prisma/prisma/pull/29986#discussion_r3765893836
- https://github.com/prisma/prisma/pull/29469#discussion_r3644139497
- https://github.com/prisma/prisma/pull/21382#discussion_r1348990521
- https://github.com/prisma/prisma/pull/18874#discussion_r1179107818
- https://github.com/prisma/prisma/pull/17950#discussion_r1109885628
- https://github.com/prisma/prisma/pull/15147#discussion_r978684569
- https://github.com/prisma/prisma/pull/13769#discussion_r904112827
- https://github.com/prisma/prisma/pull/7730#discussion_r657085406
- https://github.com/prisma/prisma/pull/7730#discussion_r656952608
- https://github.com/prisma/prisma/pull/3259#discussion_r468423459
