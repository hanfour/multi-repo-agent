---
id: common-cli-option-metadata-accuracy
layer: common
frameworks: ["typescript@*"]
severity_default: MEDIUM
---
## 觸發訊號
diff 在 `commandLineParser.ts`（或等價的「CLI/編譯器選項定義表」）裡新增或修改一個 `CommandLineOption` 物件字面量，且包含 `name`、`type`、`category: Diagnostics.xxx`、`description: Diagnostics.xxx`、`defaultValueDescription` 這幾個欄位中的任一個。特別留意：新增欄位卻沒有 `defaultValueDescription`、`category` 選用了看似不符情境的分類（例如把使用者永遠改不動的旗標放進使用者可見的 `Advanced_Options`/`Experimental_Options`）、或 `description` 文字與旗標實際語意/命名不一致。

## 判準
這張表是唯一會被序列化成 `tsc --help`、`tsconfig.json` schema、IDE 提示的地方，寫錯不會被型別系統擋下來，只會在使用者執行期被看到——所以要用「使用者會不會被這行文字誤導」的角度審查，而不是當成一般程式碼看待：
- 如果旗標其實是內部管線用途（例如透過 tsc 強制開啟、使用者永遠碰不到，或只在 API 內部使用），卻給了公開的 `description`/`category`，等於告訴使用者「這是你可以調整的東西」，但實際上不能，這是刻意誤導。
- `defaultValueDescription` 遺漏或寫錯，會讓 `--help` 輸出或文件產生器顯示錯的預設值，使用者據此設定會得到非預期行為。
- 旗標命名與 `description` 不一致（例如命名影射一件事、描述講的是另一件事，或命名比實際受影響範圍更寬/更窄），會誤導使用者選錯旗標。
- 同一份表裡重複的 `extraValidation`/`category` 邏輯之後容易複製貼上到新旗標時漏掉某個欄位，屬於這條規則的次要成因，不是主要判準。

## 嚴重度
CRITICAL：把只在內部管線用途、使用者事實上永遠無法停用/改變的旗標，公開暴露成看起來使用者可調整的選項（有 description + category，且沒有標記為 internal-only）。
HIGH：新增旗標缺少 `defaultValueDescription`，而該旗標存在非顯而易見的預設值（非 `false`/空字串等直覺預設）；或 `description` 描述的行為與程式碼實際判斷邏輯不一致。
MEDIUM：`category` 選錯（放錯 Advanced/Experimental/Type_Checking 分類）、旗標命名與描述語意有落差但不影響功能理解、或描述文字用詞不夠精準（如用內部術語而非面向使用者的措辭）。

## 反例（不該報）
- 旗標本來就標記為 `/* @internal */` 或明確走 internal-only 路徑（不出現在 `tsc --help`、`tsconfig` schema），即使 description 寫得簡略也不算問題，因為使用者本來就看不到。
- 預設值就是型別的零值（`false`、`undefined`、空陣列）且從命名即可直覺得知，省略 `defaultValueDescription` 不算缺陷。
- reviewer 只是對命名提出個人偏好式建議（"maybe X 更貼切？"），沒有指出現有名稱造成誤導或不一致，屬於品味討論而非正確性問題，不必列為此規則觸發項。
- 純粹的程式碼組織建議（例如「這些 diagnostics map 應該搬到獨立檔案」）跟本規則的「metadata 正確性」判準無關，屬於檔案組織問題，不套用本規則。

## 出處
- https://github.com/microsoft/TypeScript/pull/63077#discussion_r2749822676
- https://github.com/microsoft/TypeScript/pull/58201#discussion_r1571010341
- https://github.com/microsoft/TypeScript/pull/58220#discussion_r1569412656
- https://github.com/microsoft/TypeScript/pull/48030#discussion_r1150608117
- https://github.com/microsoft/TypeScript/pull/52921#discussion_r1120490578
- https://github.com/microsoft/TypeScript/pull/51527#discussion_r1024635390
- https://github.com/microsoft/TypeScript/pull/49863#discussion_r1016946470
- https://github.com/microsoft/TypeScript/pull/47075#discussion_r765325934
- https://github.com/microsoft/TypeScript/pull/40698#discussion_r709646667
- https://github.com/microsoft/TypeScript/pull/43542#discussion_r607418952
- https://github.com/microsoft/TypeScript/pull/39243#discussion_r488171493
- https://github.com/microsoft/TypeScript/pull/39243#discussion_r483886368
- https://github.com/microsoft/TypeScript/pull/35615#discussion_r363936212
- https://github.com/microsoft/TypeScript/pull/32356#discussion_r302755074
- https://github.com/microsoft/TypeScript/pull/25886#discussion_r230192330
- https://github.com/microsoft/TypeScript/pull/16197#discussion_r119708970
- https://github.com/microsoft/TypeScript/pull/9038#discussion_r71759850
- https://github.com/microsoft/TypeScript/pull/2652#discussion_r27891388
