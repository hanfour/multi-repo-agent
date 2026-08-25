---
id: common-span-must-always-end
layer: common
frameworks: ["@opentelemetry/api@*"]
severity_default: HIGH

---
## 觸發訊號

diff 裡新增或修改了會建立 tracer span 的程式碼（`tracer.startSpan(...)`、`tracer.startActiveSpan(name, callback)`、或手動 `new Span(...)` 之類的建構），而 span 存活期間會呼叫「可能拋例外」的程式碼——尤其是使用者提供的 callback、event listener、middleware、下游 I/O（DB query、network call、序列化）——卻沒有用 `try/finally`（或等效機制）保證 `span.end()` 在拋例外、提早 return 等所有路徑上都會被呼叫。同樣要注意：span 建立與 span 結束分散在不同函式/不同 executor（例如 local path 與 remote path 各自實作一次）時，其中一條路徑漏掉了對稱的 end 邏輯。

## 判準

沒有被 `end()` 的 span 不會被匯出，也不會在 tracing 後端顯示為「已完成」——它就是靜靜消失，或者在某些後端裡停留成永遠「in-flight」的殘留 span，污染 trace 資料且難以事後定位。這種 leak 特別危險的地方在於：一旦 span 的 callback 範圍內第一次放進了「使用者程式碼」（listener、middleware），例外就從理論上可能發生變成實際上會發生，而過去 span 建立/結束是同步、不可能被中途打斷的，這個假設一旦被打破就是 regression。此外，「保證 span.end() 一定執行」跟「吞掉 callback 拋出的例外」是兩個完全不同的設計決策，不要因為要修 span leak 就順手把例外吞掉——那是會隱藏使用者 bug 的另一個決定，需要獨立討論。

## 嚴重度

CRITICAL：span 包住的是任意使用者提供的 callback（event listener、middleware、plugin hook），且該 span 位於高頻路徑（例如每次 query 都會建立）——leak 會快速累積，直接污染生產環境的 tracing 資料。
HIGH：span 包住的是內部 engine/framework 程式碼但仍可能拋例外（下游 I/O、解析、序列化），沒有 try/finally 保證 end。
MEDIUM：span 建立與結束的對稱性依賴「這段程式碼目前不會拋例外」的隱性假設，而非結構性保證（例如靠上游已經 catch 過，但沒有在本函式內顯式保證）。

## 反例（不該報）

- span 只包住無外部呼叫、不可能拋例外的純同步賦值/序列化程式碼，中間沒有任何會拋例外的操作。
- PR 已經加了 `try/finally` 讓 `span.end()` 一定執行，但沒有額外把 callback 的例外吞掉／swallow——這是刻意的分離決策（保證 span 生命週期正確 ≠ 保證例外不會傳播），不能因為「例外還是會往外拋」就當成同一個問題重報。
- 使用像 OTel API 官方的 `tracer.startActiveSpan(name, callback)` 且該 API 本身在文件與實作上保證即使 callback 拋出例外也會呼叫 end（視版本與呼叫方式而定）——此時不需要外層再包一層 try/finally，除非能具體指出該保證不成立的路徑。

## 出處

- https://github.com/nestjs/nest/pull/11571#discussion_r1180658560
- https://github.com/nestjs/nest/pull/9999#discussion_r927182000
- https://github.com/nestjs/nest/pull/6428#discussion_r594100234
- https://github.com/prisma/prisma/pull/28892#discussion_r3622988763
- https://github.com/prisma/prisma/pull/29262#discussion_r2863120280
- https://github.com/prisma/prisma/pull/28062#discussion_r2333839654
- https://github.com/prisma/prisma/pull/28062#discussion_r2333030198
- https://github.com/prisma/prisma/pull/26727#discussion_r2038913848
- https://github.com/prisma/prisma/pull/26727#discussion_r2037193131
- https://github.com/prisma/prisma/pull/26601#discussion_r2001175288
- https://github.com/prisma/prisma/pull/20113#discussion_r1986928868
- https://github.com/prisma/prisma/pull/20113#discussion_r1985118454
- https://github.com/prisma/prisma/pull/25828#discussion_r1886616329
- https://github.com/prisma/prisma/pull/22139#discussion_r1408393513
- https://github.com/prisma/prisma/pull/21811#discussion_r1383674836
- https://github.com/prisma/prisma/pull/21200#discussion_r1334939515
- https://github.com/prisma/prisma/pull/21076#discussion_r1327086076
- https://github.com/prisma/prisma/pull/20113#discussion_r1277715723
- https://github.com/prisma/prisma/pull/20231#discussion_r1265141658
- https://github.com/prisma/prisma/pull/14498#discussion_r932505203
- https://github.com/prisma/prisma/pull/3971#discussion_r509143505
- https://github.com/prisma/prisma/pull/3971#discussion_r509140984
- https://github.com/prisma/prisma/pull/3585#discussion_r487042254
- https://github.com/prisma/prisma/pull/3585#discussion_r486458879
