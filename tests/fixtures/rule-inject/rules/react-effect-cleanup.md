---
id: react-effect-cleanup
layer: react
frameworks: ["react@>=18"]
severity_default: MEDIUM
---
## 觸發訊號
`useEffect` 訂閱了外部事件或計時器，但 cleanup function 沒有取消訂閱。

## 判準
沒有 cleanup 的訂閱會在元件卸載後繼續觸發回呼，造成記憶體洩漏或
setState-on-unmounted 警告。

## 嚴重度
MEDIUM：沒有 crash，但長期執行會累積洩漏。

## 反例（不該報）
訂閱的目標本來就是元件生命週期外的全域單例，且該單例自己有去重機制。

## 出處
- https://github.com/facebook/react/pull/3001#discussion_r300001
- https://github.com/facebook/react/pull/3002#discussion_r300002
- https://github.com/facebook/react/pull/3003#discussion_r300003
