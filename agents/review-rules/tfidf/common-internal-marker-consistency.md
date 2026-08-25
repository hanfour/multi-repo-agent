---
id: common-internal-marker-consistency
layer: common
frameworks: []
severity_default: MEDIUM
---
## 觸發訊號
diff 裡新增或修改了 export 出去的 function、const、property、enum member、interface method，但沒有標記內部可見性註解（如 `/** @internal */`、`/* @internal */`）；或是反過來：某個標記了 `@internal` 的成員其實已經不再被外部匯出（未 export / 未出現在 public API baseline），標記變成多餘。也包含：把已存在的 `@internal` 成員直接刪除，而非保留標記讓死碼可被未來復用。

## 判準
`@internal` 這類標記是 public API 邊界的唯一防線 —— 少標一個，該符號就會被打包進對外型別宣告（.d.ts）或 API baseline，變成使用者可依賴的公開介面，之後想拿掉就是 breaking change。多標或標記位置錯誤（例如標在未被 export 的成員上）則是雜訊，容易誤導後續維護者以為它有暴露風險。這類問題經常在重構、搬移程式碼、或新增 helper function 時被漏掉，因為作者當下的意圖是「內部工具」，但沒有意識到宣告本身已經是 exported。

## 嚴重度
CRITICAL：新增的 exported 符號明顯是內部實作細節（helper、內部 flag、內部訊息型別），卻完全沒有 internal 標記，且該 repo 有自動化 public API baseline / .d.ts 測試會因此固化成公開 API。
HIGH：修改或搬移既有已標記 `@internal` 的符號時漏掉重新加註記，或新增的 enum member／interface method 沒有依循同檔案其他成員一致的 internal 標記慣例。
MEDIUM：`@internal` 標記位置不理想（例如可以標在更聚焦的宣告上、或該放在型別而非其中一個方法上）、或標記了實際上未 export 因此不需要標記的成員。

## 反例（不該報）
- 成員本身未被任何 export 語句匯出（不論是否在 namespace 內部），本來就不會出現在 public API 中，不需要 `@internal`。
- 純粹刪除已死亡、確定不再需要、也沒有 API baseline 顧慮的程式碼，且該刪除不影響任何仍存在的 public 型別。
- 為了讓 enum member 的宣告順序更符合語意而搬移位置，未新增或移除任何 export/internal 標記。
- 專案根本沒有 public API baseline / .d.ts 產出機制，`@internal` 標記對外部使用者不構成任何實際影響時，此為風格建議而非缺陷。

## 出處
- https://github.com/microsoft/TypeScript/pull/56817#discussion_r1442330175
- https://github.com/microsoft/TypeScript/pull/52562#discussion_r1096342706
- https://github.com/microsoft/TypeScript/pull/47924#discussion_r817187168
- https://github.com/microsoft/TypeScript/pull/43370#discussion_r601934834
- https://github.com/microsoft/TypeScript/pull/33771#discussion_r445099133
- https://github.com/microsoft/TypeScript/pull/36688#discussion_r385395804
- https://github.com/microsoft/TypeScript/pull/35742#discussion_r359401440
- https://github.com/microsoft/TypeScript/pull/19689#discussion_r149283688
- https://github.com/microsoft/TypeScript/pull/18860#discussion_r141987756
- https://github.com/microsoft/TypeScript/pull/12336#discussion_r121565082
- https://github.com/microsoft/TypeScript/pull/15935#discussion_r120502374
