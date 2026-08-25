---
id: common-ci-config-logic-mismatch
layer: common
frameworks: ["github-actions@*", "renovate@*"]
severity_default: HIGH

---
## 觸發訊號
diff 修改了 CI/CD 或工具設定檔（`.github/workflows/*.yml` 的 `if:`／`concurrency:`／`cancel-in-progress:` 等條件式表達式、`renovate.json`、`CODEOWNERS` 等）中的下列任一項：
- 布林/條件表達式被改寫，且相鄰註解或 PR 描述陳述的意圖（例如「schedule 觸發時不要取消」）與表達式實際的真值結果相反或不一致
- 新增的 JSON/YAML key 與同一檔案中既有的同名 key 重複（例如 `renovate.json` 裡兩次出現 `"schedule"`），且新舊值不同
- 移除一段沒有註解說明用途、但明顯是為了防止某種副作用（如物件被意外 mutate、重複觸發）而存在的條件分支，卻沒有先確認移除後行為是否仍安全

## 判準
這類檔案通常沒有型別檢查或 lint 會抓出邏輯反轉、重複 key 或分支移除的副作用——YAML/JSON 對重複 key 的處理是後者靜默覆蓋前者，不會報錯，也不會在本地測試中被發現；而 CI 條件式的錯誤只會在特定觸發情境（例如 `schedule` event、特定 job 併發）下才顯現，等到觀察到 job 被誤取消或設定沒生效時，往往已經造成資料遺失（例如 flaky test 偵測的 buildpulse 結果被取消掉）或規則長期失效卻無人察覺。資深 reviewer 對這類改動的判斷方式是「先讀懂原本那段程式碼/設定是為了防止什麼，再確認新版本是否還防得住」，而不是只看 diff 表面是否「更簡潔」。

## 嚴重度
CRITICAL：重複 key 或反轉邏輯導致原本用來擋下危險操作（例如阻擋部署、擋下未授權變更）的機制失效
HIGH：CI concurrency/cancellation 邏輯顛倒，導致重要 job（release build、flaky test 偵測）被誤取消或誤放行；或 duplicate key 使其中一個設定值完全失效且短期內不易被發現
MEDIUM：`renovate.json` schedule、`CODEOWNERS` 等非阻斷性設定的邏輯錯誤，影響範圍侷限於排程時機或通知對象，不影響正確性或安全性

## 反例（不該報）
- 同一 key 重複出現但值完全相同（雖然多餘、可以合併，但不改變實際行為，屬於程式碼整潔問題而非邏輯錯誤）
- 使用 YAML anchor/merge key（`<<: *default`）等該格式明確支援的覆寫語法，且行為與命名/註解一致
- 移除的分支本身有清楚的 commit/PR 說明「此邏輯已不需要，原因是 X」，且改動者已確認過下游沒有依賴該行為
- reviewer 自己承認「這只是先移除，之後需要再加回來」的暫時性、雙方已達成共識的過渡狀態變更

## 出處
- https://github.com/nestjs/swagger/pull/1137#discussion_r559383291
- https://github.com/prisma/prisma/pull/19001#discussion_r1186097193
- https://github.com/prisma/prisma/pull/13728#discussion_r870592428
- https://github.com/prisma/prisma/pull/13299#discussion_r870592428
- https://github.com/prisma/prisma/pull/7898#discussion_r659679791
