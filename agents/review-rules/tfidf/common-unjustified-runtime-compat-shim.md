---
id: common-unjustified-runtime-compat-shim
layer: common
frameworks: ["node@*"]
severity_default: MEDIUM
---
## 觸發訊號
diff 裡出現以下任一種樣式：
1. 針對「舊版 runtime」的相容性 workaround（例如 Node < 18 對 `Blob`/`TypedArray`/`ArrayBuffer` byte 處理不同、要先轉成 single-byte array 才能繞過），但沒有註明「目前專案實際支援的最低版本」或「這段 workaround 何時可以移除」。
2. 因為某個內建全域變數（如 Node 的 `Buffer`）觸發 lint 的 `no-undef`，改用改名（`Buf`）、加自訂 wrapper、或其他繞過寫法，而不是用該 lint 工具標準的 escape 機制（如 `/* global Buffer */`、`// eslint-disable-next-line`）。

## 判準
資深 reviewer 在意的不是「這段 workaround 對不對」，而是「這段 workaround 有沒有跟支援矩陣綁定」。相容性 shim 一旦寫進去，若沒有明確的版本邊界或移除條件，就會變成沒人敢動的死重碼——沒人記得為什麼要繞、也沒人敢刪，等於把技術債焊死在程式碼裡；若專案早就不再支援那個舊版本，這段複雜度純粹是噪音跟潛在 bug 來源。另一方面，用改名來閃避 lint 錯誤（而非用工具本身提供的 escape）會讓程式碼讀起來跟全 repo 慣例不一致，reviewer/後續維護者看到 `Buf` 反而要多花一步確認「這跟 `Buffer` 是不是同一個東西」，等於用可讀性換取表面上的 lint 綠燈。

## 嚴重度
CRITICAL：workaround 改變了資料正確性（例如 binary/byte 內容被不同版本處理成不同結果），但沒有對應測試覆蓋，一旦支援版本邊界跑掉會產生無聲的資料錯誤。
HIGH：相容性 shim 沒有任何註解或版本檢查綁定「支援到哪個版本」，導致該分支永遠不會被回頭審視、清除。
MEDIUM：為了閃避 lint 錯誤而改名或繞路寫法（而非使用該 lint 工具的標準 escape），造成程式碼風格與全 repo 慣例不一致。

## 反例（不該報）
- Workaround 有清楚寫明「支援到 Node X」且有對應測試/CI 版本矩陣覆蓋，屬於已管理好的技術債，不用報。
- 改名不是為了閃避 lint，而是有真實語意理由（例如區分兩個不同用途的同名變數）。
- 已經正確使用 lint 工具提供的標準 escape（`/* global Buffer */`、`eslint-disable-next-line`）而非繞路改名，這是正確做法，不該報。

## 出處
- https://github.com/react/react/pull/28887#discussion_r1579856722
- https://github.com/react/react/pull/25480#discussion_r997248950
- https://github.com/react/react/pull/3123#discussion_r24615130
