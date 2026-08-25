---
id: nestjs-microservices-async-ordering-hazard
layer: nestjs
frameworks: ["@nestjs/microservices@*"]
severity_default: HIGH
---
## 觸發訊號
在 `@nestjs/microservices` 的 client/server transport 實作（`client-kafka.ts`、`server-kafka.ts`、`server-mqtt.ts` 這類檔案）中出現以下任一模式：
- 原本同步的 `serializer.serialize(...)` 或類似操作被改成回傳 `Promise` 並以 `.then(...)`／`await` 包裝，而 `this.routingMap.set(packet.id, callback)`（或任何用來追蹤 in-flight 請求／訂閱者的 Map/Set 寫入）被搬到該 async callback 內部才執行，晚於呼叫端可能觸發的 `close()`/`unsubscribe()`/`disconnect()`。
- async 函式最後一行是 `return await somePromise;`，外層沒有包 `try/catch`。
- 對 `Map`/`Set` 實例呼叫 `Object.keys(mapInstance)` 或 `Object.values(mapInstance)` 來取得 key/value 列表。

## 判準
把序列化這類原本同步的操作改成非同步之後，「登記追蹤中請求」的副作用（`routingMap.set`）也被延後執行；如果呼叫方在 Promise resolve 之前就已經 disconnect/unsubscribe，對應的 callback 永遠不會被寫入清除邏輯覆蓋到，造成 entry 累積在 map 裡出不去（memory leak），嚴重時甚至讓等待回覆的呼叫方永遠 pending。`return await` 在沒有 try/catch 的情況下只多一個 microtask、沒有任何語義收益，屬於浪費效能且容易誤導後續維護者以為此處刻意需要等待。`Object.keys()/Object.values()` 用在 `Map` 上會回傳空陣列，因為 Map 的 entries 不是實例自身可列舉的字串屬性，這是一個非常隱蔽、TypeScript 型別也不會攔的邏輯錯誤，直接導致遍歷結果永遠是空的。

## 嚴重度
CRITICAL：ordering 問題會造成請求方永久等待不會到來的回覆（例如 request-reply pattern 的 callback 因 unsubscribe race 未被正確登記/清除，導致呼叫方 timeout 或掛住）。
HIGH：明確的 memory leak（routingMap 或其他追蹤結構的 entry 只增不減，但不影響單次呼叫的正確性），或 `Object.keys()/values()` 用錯 API 導致遍歷結果永遠是空集合而功能整個失效。
MEDIUM：單純的 `return await` 冗餘寫法，或 Map API 誤用但因呼叫情境恰好不影響觀察得到的行為（如結果立即被丟棄、有其他機制兜底）。

## 反例（不該報）
- async chain 中沒有任何跨呼叫共享的可變狀態（純粹非同步取得資料後直接使用/送出，沒有另外的 map/set 在追蹤 in-flight 請求），不構成 ordering 風險。
- `return await` 外層確實包了 `try/catch` 需要在該層攔截錯誤——這是必要寫法，不該報。
- `Object.keys()/Object.values()` 作用在確定是 plain object 或 array 的資料上完全正確，只有目標是 `Map`/`Set` 實例時才成立本規則。
- 純粹解釋既有程式碼設計意圖的 review comment（例如說明 `.then` 用法是刻意選擇、或說明某函式並非 async 所以呼叫是同步的），沒有指出需要修改的具體風險，不算需要觸發本規則的問題。

## 出處
- https://github.com/nestjs/nest/pull/11026#discussion_r1095587932
- https://github.com/nestjs/nest/pull/9290#discussion_r819131745
- https://github.com/nestjs/nest/pull/8796#discussion_r772891587
- https://github.com/nestjs/nest/pull/8796#discussion_r770285741
- https://github.com/nestjs/nest/pull/8796#discussion_r770285314
- https://github.com/nestjs/nest/pull/1161#discussion_r222604088
