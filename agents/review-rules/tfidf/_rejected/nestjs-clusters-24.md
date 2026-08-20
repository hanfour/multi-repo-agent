---
id: nestjs-force-destroy-connections-on-close
layer: nestjs
frameworks: ["@nestjs/platform-express@*"]
severity_default: HIGH

## 觸發訊號
diff 在 HTTP adapter(如 `express-adapter.ts`、`fastify-adapter.ts`)的 `close()` 或 shutdown 相關方法中,新增類似 `this.openConnections.forEach(socket => socket.destroy())` 的邏輯,直接對所有目前開啟的連線呼叫 `socket.destroy()`/`socket.end()`,而且沒有對應的旗標(例如 `forceCloseConnections`)讓使用者選擇是否啟用,也沒有預設為 `false`/opt-in 的判斷邏輯包住這段程式碼。

## 判準
強制關閉所有仍在使用中的 TCP 連線是會影響既有使用者的行為變更(breaking change)——原本呼叫 `.close()` 或 `enableShutdownHooks()` 應該是停止接受新連線、並讓既有請求自然完成,如果改成無條件 destroy 所有 open sockets,長時間執行的請求(SSE、長輪詢、檔案上傳/下載)會被中途強制中斷。Fastify 已經用一個顯式、預設關閉的 `forceCloseConnections` 選項處理這個需求,因此其他 adapter 若要加同樣的能力,也必須用同樣明確、預設 false 的旗標讓使用者選擇加入,而不是內建成無法關閉的行為,否則使用者升級後會在毫無預警的情況下看到連線被強制中斷。

## 嚴重度
CRITICAL: 強制關閉連線的邏輯被合併進 minor/patch release,且完全沒有旗標或設定可以停用,導致所有既有使用者升級後行為改變且無法退回舊行為。
HIGH: 新增了 force-close 邏輯,但預設就是啟用(未做成 opt-in),或未在 CHANGELOG / migration guide 中標註為 breaking change。
MEDIUM: 有做成旗標且預設關閉,但旗標命名或掛載位置與既有框架慣例(如 Fastify 的 `forceCloseConnections`)不一致,增加使用者遷移或跨 adapter 切換時的認知負擔。

## 反例（不該報）
若 `close()` 中只是呼叫 `server.close()` 等待既有連線自然結束、並未主動 destroy socket,不適用此規則;若強制關閉邏輯已包在一個預設為 `false` 的旗標(如 `forceCloseConnections`)之後,且該行為已在文件或 PR 描述中明確標注,不算違規;若 destroy 只作用於已經逾時的 idle/keep-alive 連線(有明確的逾時判斷邏輯),而非所有 open connections,也不屬於這條規則要抓的問題。

## 出處
- https://github.com/nestjs/nest/pull/10345#discussion_r987573536
- https://github.com/nestjs/nest/pull/10345#discussion_r986498427
