---
id: common-debug-artifact
layer: common
frameworks: ["*"]
severity_default: LOW
---
## 觸發訊號
diff 裡新增了 `console.log`／`debugger`／註解掉的除錯程式碼，且看起來不是
刻意留下的日誌。

## 判準
除錯殘留物會污染正式輸出或洩漏內部狀態，屬於清理範疇的問題，跟語言、
框架無關，所以歸在 common 層。

## 嚴重度
LOW：不影響功能，但屬於該清掉的雜訊。

## 反例（不該報）
明確標註為正式日誌（例如帶 log level 或走 logger 而非裸 console.log）。

## 出處
- https://github.com/microsoft/TypeScript/pull/4001#discussion_r400001
- https://github.com/microsoft/TypeScript/pull/4002#discussion_r400002
- https://github.com/microsoft/TypeScript/pull/4003#discussion_r400003
- https://github.com/microsoft/TypeScript/pull/4004#discussion_r400004
