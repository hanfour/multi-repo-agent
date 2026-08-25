---
id: nestjs-fragile-response-header-heuristic
layer: nestjs
frameworks: ["@nestjs/platform-fastify@*", "@nestjs/platform-express@*", "@nestjs/common@*"]
severity_default: MEDIUM
---
## 觸發訊號
diff 在 HTTP adapter（`platform-fastify`/`platform-express` 的 adapter 或 `router-response-controller` 等框架層程式碼）新增了根據 response 的 `Content-Type` header 字串、`body?.statusCode` 或其他回應/body 形狀去「推斷」目前是否為錯誤回應、要不要覆寫 body 或套用特殊處理的分支，而不是由 NestJS 的 exception filter / 明確旗標告知。典型寫法：`fastifyReply.getHeader('Content-Type') !== 'application/json' && body?.statusCode === HttpStatus.INTERNAL_SERVER_ERROR` 這種組合條件。

## 判準
用「Content-Type 不是 json」加上「body 剛好有個 statusCode 欄位」去猜測「這是一筆錯誤回應」是巧合式的啟發式判斷（heuristic），不是明確契約。這種判斷一定會漏掉其他同樣合理的情境：例如 controller 本來就打算回傳 `application/scim+json` 這類非標準 JSON 子型別的物件，或錯誤實際上是 401/404 而不是 500，都會落入或漏出這個分支，行為變得不可預期、也難以在本地推理（reviewer 原話：「it's technically incorrect... its behaviour is unpredictable」）。正確做法是要有明確訊號（獨立方法、旗標、或走 exception filter 契約），而不是拿 response/body 的既有欄位做字串或型別比對來反推狀態。

## 嚴重度
CRITICAL：啟發式判斷會在正常請求路徑上靜默覆寫或丟棄使用者刻意回傳的資料（例如把使用者自訂的非 JSON body 誤判為錯誤而替換掉），且沒有旁路開關。
HIGH：review 當下已明確承認這個判斷條件無法涵蓋其他真實會出現的狀態碼或 content-type（如 401、404，或 `application/scim+json` 等其他 JSON 子型別），但仍照原樣合併。
MEDIUM：啟發式判斷只用於邊角情境的提示/開發輔助訊息（例如 console 警告），誤判只影響 DX 不影響回應正確性。

## 反例（不該報）
單純「尚未設定就補預設值」的存在性檢查不算，例如 `if (response.getHeader('Content-Type') === undefined) { response.setHeader(...) }` 這種只是「還沒被設過就補上」，不涉及推斷錯誤狀態。另外，若狀態碼判斷本來就是該方法明確文件化的契約（例如一個 API client 函式本來就定義「4xx/5xx 視為錯誤」），如 `if (response.status >= 400) throw new Error(text)`，屬於明確契約而非巧合式啟發，也不該報。

## 出處
- https://github.com/nestjs/nest/pull/10474#discussion_r1008659953
- https://github.com/nestjs/nest/pull/10474#discussion_r1008113263
- https://github.com/nestjs/nest/pull/10474#discussion_r1008105677
- https://github.com/nestjs/nest/pull/10474#discussion_r1008022307
- https://github.com/nestjs/nest/pull/7589#discussion_r671581508
