---
id: common-unexplained-runtime-workaround
layer: common
frameworks: ["*"]
severity_default: MEDIUM
---
## 觸發訊號
diff 中新增了一段「補丁式」程式碼，用來讓某個環境相依的失敗現象消失，但看不到任何解釋為什麼需要它、或原本為什麼會壞。具體型態包括：
- 測試檔案裡直接塞入 global polyfill（如 `global.TextEncoder = require('util').TextEncoder`），且沒有註解說明是哪個 production 路徑依賴這個全域物件、或為什麼測試環境原本沒有它。
- 元件依據非同步取得的能力旗標（如 `supportsSynchronousXHR`）在 `useEffect` 裡動態改變 UI 狀態（disable 按鈕、跳出 modal），但旗標初始值與非同步更新之間存在「先啟用、後停用」的時序落差，PR 裡沒有處理或討論這個 race。
- PR 修改的區塊（如共用的 DOM property/config 表）與另一個尚未合併、範圍重疊的 PR 撞在一起，作者自己都在問是否該關掉重送。

## 判準
這類改動通常是為了讓 CI 綠燈或功能能動而先加上去的，但 reviewer 自己在留言裡用「Hmm」「sign of a bigger issue?」表達不確定——代表根本原因（root cause）從頭到尾沒有被真正診斷過。放行這種未解釋的 workaround 會帶來兩個實際風險：一是把真正的 bug（例如能力偵測的 race condition、production code 實際上依賴一個沒被保證存在的全域物件）藏在補丁底下，日後很難追；二是如果同一塊程式碼同時有別的 PR 在動，未協調的重疊修改會造成合併衝突或邏輯互相打架，浪費雙方工時。

## 嚴重度
CRITICAL：workaround 掩蓋的是 production 執行路徑上會造成錯誤使用者體感的 bug，例如能力旗標的非同步時序讓使用者短暫看到「應該被停用卻被啟用」的互動元件。
HIGH：production 程式碼隱含依賴一個沒有在真實執行環境中被保證提供的能力/全域物件（只在測試裡 polyfill，正式環境沒有對應的 shim 或降級處理）。
MEDIUM：改動的範圍與另一個尚在進行中、未協調的 PR 明顯重疊，有重工或合併衝突風險；或是測試專用的 workaround 缺乏解釋，但對正式功能無立即風險。

## 反例（不該報）
- 該 polyfill 是加在專案既有的共用 test-setup 檔案裡，且是業界已知、常見的環境落差（例如 jsdom 本來就不含 `TextEncoder`），团队其他測試也已經用同樣方式處理過。
- 能力偵測的分支有清楚的測試或註解說明每個狀態（載入中/支援/不支援）該呈現什麼 UI，沒有先啟用再停用的時序問題。
- PR 作者已經在 comment 或 PR description 裡明確與另一個重疊 PR 的作者協調好合併順序，重疊是刻意且已知的過渡狀態。

## 出處
- https://github.com/react/react/pull/24291#discussion_r845438183
- https://github.com/react/react/pull/20879#discussion_r583195238
- https://github.com/react/react/pull/7474#discussion_r78965991
