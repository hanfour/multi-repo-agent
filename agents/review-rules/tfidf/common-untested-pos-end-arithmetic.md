---
id: common-untested-pos-end-arithmetic
layer: common
frameworks: ["typescript@*"]
severity_default: HIGH
---
## 觸發訊號
diff 中對 scanner / text-editing / incremental-range 這類程式碬手動運算 `pos`、`end`、`offset` 或 range 的加減（例如 `location.end - location.pos`、`pos + offset`、`deletionNeeded = ... - ...`、對 `while` 迴圈條件加上 `+1`/`-1` 調整、或新增一個影響字元分類/終止條件的 boolean 判斷如 `|| char === CharacterCodes.xxx`），且同一個 diff 裡沒有一併新增涵蓋該邊界情況（tab、換行、zero-length range、unicode surrogate、字串邊界）的測試案例或 baseline。

## 判準
這類 pos/end 算術錯誤不會拋例外、不會讓 build 失敗，只會在特定輸入（tab 字元、0 長度選取、多位元組字元、字串首尾）下悄悄產生錯誤的 token 範圍或編輯結果，而且這條路徑在每次 scan/paste 都會跑到，一旦錯誤會往下游（parser、formatter、language service）靜默擴散且很難回溯定位。resident reviewer 對這類調整的預設反應是「這個 +1/-1 為什麼需要，有沒有反例證明現有邏輯錯了」——沒有測試就等於沒人驗證過這個調整是對的，也没人能在未來重構時安全地移除它。

## 嚴重度
CRITICAL：pos/end 調整錯誤可能造成無窮迴圈、陣列/字串界外存取，或讓 scanner 卡死（例如條件寫反導致 `pos` 永遠不前進）。
HIGH：新增或修改了 pos/end 偏移運算（尤其牽涉 unterminated/malformed input 的復原邏輯，如 regex 未閉合、paste range 重疊），且沒有測試涵蓋觸發該分支的邊界輸入。
MEDIUM：邏輯看起來正確，但新加入一個先前未覆蓋的字元類別/邊界情況（例如 tab、0 長度 range）卻沒有對應測試或 baseline 更新。

## 反例（不該報）
- pos/end 只是單純的 slice 起訖點傳遞（未做任何 +1/-1 或條件式調整），且行為與既有測試路徑一致。
- 調整有對應的新測試案例或 baseline 檔案佐證（即使測試寫得簡略，只要能重現該邊界輸入）。
- 純粹的變數重新命名或型別註記變動，沒有改變任何算術運算本身。

## 出處
- https://github.com/microsoft/TypeScript/pull/63581#discussion_r3468850566
- https://github.com/microsoft/TypeScript/pull/60628#discussion_r1861233736
- https://github.com/microsoft/TypeScript/pull/59542#discussion_r1728063301
- https://github.com/microsoft/TypeScript/pull/59542#discussion_r1715976992
- https://github.com/microsoft/TypeScript/pull/59542#discussion_r1714353603
- https://github.com/microsoft/TypeScript/pull/58289#discussion_r1611882856
- https://github.com/microsoft/TypeScript/pull/58289#discussion_r1607344886
- https://github.com/microsoft/TypeScript/pull/58320#discussion_r1609030673
- https://github.com/microsoft/TypeScript/pull/58320#discussion_r1604036981
- https://github.com/microsoft/TypeScript/pull/53869#discussion_r1179489431
- https://github.com/microsoft/TypeScript/pull/50918#discussion_r984021583
- https://github.com/microsoft/TypeScript/pull/30829#discussion_r299620571
