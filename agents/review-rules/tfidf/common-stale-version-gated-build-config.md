---
id: common-stale-version-gated-build-config
layer: common
frameworks: ["typescript@*"]
severity_default: MEDIUM
---
## 觸發訊號
diff 修改了與工具/語言版本綁定的建置設定或條件邏輯，具體包括：(1) `tsconfig.json` 的 `lib`/`target` 改成籠統值（例如 `esnext`）而非對應實際使用的最低語言特性版本；(2) babel/TS parser 的 plugin 清單依 TypeScript 版本差異手動 push 特定 plugin（例如 `importAttributes`/`importAssertions` 這類同語法家族但互斥或重疊的旗標），且用 `userPlugins.includes(...)` 只檢查其中一個旗標、沒有檢查同組的其他別名/替代旗標。

## 判準
`lib`/`target` 設太籠統（如 `esnext`）會讓程式在不自知的情況下用到超出套件實際承諾支援範圍的 runtime API，等到消費者在較舊環境執行才爆炸；同時它也掩蓋了「這段程式碼實際依賴哪個語言版本特性」這個資訊，之後想收緊範圍會不知道安全下限在哪。版本綁定的 plugin 清單則是另一種脆弱點：TS 的語法支援會跨版本變動（例如 5.2 只支援 `assert`、5.3 才同時支援 `assert`/`with`），寫死的 push 邏輯很快就會過期；而 `includes()` 守衛如果只查一個旗標名稱，使用者若已經自行指定了同組的另一個旗標，程式仍會重複 push，造成 plugin 重複註冊或蓋掉使用者原本要的選項。

## 嚴重度
CRITICAL：版本綁定的 plugin 邏輯造成穩定版對合法使用者輸入（含使用者自訂的同組 plugin 設定）解析失敗或行為被靜默覆蓋。
HIGH：`lib`/`target` 設得過於籠統，導致套件在宣稱支援的最低環境上會因用到未經保證的 runtime API 而在執行期出錯，且沒有任何測試或註解說明實際最低需求。
MEDIUM：`includes()` 守衛漏查同組的替代旗標，目前不會造成功能性錯誤，但會產生重複註冊或很快隨 TS 版本更新而過期的隱性耦合。

## 反例（不該報）
刻意將 `lib`/`target` 設為籠統值，且該套件本來就只給內部工具鏈或已知只跑在最新 Node/瀏覽器的場景使用（非對外發佈的 library）；`lib`/`target` 的調整有明確理由（例如 review 中指出程式碼實際用了哪個 ES 版本特性）並收斂到對應版本；plugin 版本判斷邏輯有正確檢查同組所有互斥/重疊旗標、讓使用者能覆寫預設值。

## 出處
- https://github.com/vuejs/vue/pull/5887#discussion_r130786069
- https://github.com/vuejs/core/pull/10164#discussion_r1481500808
- https://github.com/vuejs/core/pull/10164#discussion_r1481261570
- https://github.com/vuejs/core/pull/8786#discussion_r1366809406
- https://github.com/vuejs/core/pull/8786#discussion_r1366762363
- https://github.com/vuejs/core/pull/8786#discussion_r1366733566
