# mra test-audit

以 Kent Beck 的 11 條好測試原則稽核測試檔案。

```bash
mra test-audit frontend-app
MRA_AUDIT_PARALLEL=3 mra test-audit frontend-app   # cap concurrent audits
```

## 探索規則

尋找符合以下模式的檔案：
- `*.test.*`（JS / TS）
- `*_test.*`（Go）
- `*.spec.*`（Ruby、JS）

排除 `node_modules`、`dist`、`build`、`vendor`、`.git`。

## 11 條原則

1. **Isolated（隔離）** — 測試之間不依賴彼此的狀態
2. **Composable（可組合）** — 小單元能乾淨地組合
3. **Fast（快速）** — 整個 suite 在幾秒內跑完
4. **Inspiring（啟發設計）** — 測試的設計能啟發程式碼的設計
5. **Writable（好寫）** — 撰寫測試的成本很低
6. **Readable（好讀）** — 測試讀起來就像規格
7. **Behavioural（驗證行為）** — 測試驗證行為，而非實作
8. **Structure-insensitive（不受結構影響）** — 重構不會弄壞測試
9. **Automated（自動化）** — 測試不需人工介入即可執行
10. **Specific（指向明確）** — 一個失敗對應單一原因
11. **Deterministic（確定性）** — 相同輸入，每次都得到相同結果

## 輸出

每個檔案一份 Markdown，列出 CRITICAL/HIGH/MEDIUM 發現，並標註對應的原則編號與 file:line 證據。
