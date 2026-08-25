---
id: common-benchmark-noise-and-nondeterminism
layer: common
frameworks: ["benchmark.js@*", "@codspeed/*@*"]
severity_default: MEDIUM
---
## 觸發訊號
diff 中新增或修改效能測試/benchmark 檔（`*.bench.ts`、`bench.ts`、`scripts/bench.ts`、`benchmarks/**`），且符合下列任一種：
- PR 描述或 review comment 用單次本機 `ops/sec (N runs sampled)` 結果作為選擇演算法/資料結構/依賴套件（如 hash 演算法、UUID 產生器、序列化方式)的唯一依據，沒有附上在 CI/CodSpeed 等隔離、可重跑環境下的多次量測。
- benchmark 腳本改動了執行旗標、warmup、JIT 相關設定（如 `--no-opt`、V8 flags、關閉 warmup runs），卻沒有討論這對優化/未優化程式碼行為差異的影響。
- 新增的 benchmark 依賴（如 `@codspeed/*`）被放進 `dependencies` 而非 `devDependencies`，或 benchmark 用的複雜型別/工具函式被 inline 進單一檔案而不是共用匯出。
- 新增的 seed/fixture 產生邏輯（機率分布、關聯圖生成）沒有註解說明模擬的情境，讓後續改動者難以判斷 benchmark 資料是否仍具代表性。

## 判準
Benchmark 數字本身容易產生誤導：JIT 優化與未優化路徑的效能特性可能完全反轉（同一組程式碼在有無 `--opt` 下可以出現 20 倍以上的排名反轉），單機單次跑分的 `±3%` 誤差範圍也不足以支撐"為了效能而換演算法/依賴"這種決策，尤其當差異本身只有個位數 ns、在整體請求中可忽略不計。同時 benchmark 是長期會被重跑、比較歷史趨勢的資產（如 CodSpeed track record），若目錄結構、依賴分類、資料生成邏輯不清楚會讓後續人很難信任或維護這些數字。

## 嚴重度
CRITICAL：僅憑本機單次跑分數字，就把一個影響正確性或既有明確語意的核心邏輯（如 deterministic ID 產生方式）替換掉，且沒有評估替換對下游行為（例如從隨機碰撞率、雜湊強度需求）的影響。
HIGH：用未經多次/CI 環境驗證的 benchmark 結果來決定演算法或依賴選型，而該選型會影響到生產路徑效能特性，且改動幅度可觀（換函式庫、換序列化協定）。
MEDIUM：benchmark 相關依賴放錯 dependencies/devDependencies 分類；benchmark 腳本調整 warmup/優化旗標但未說明取捨；新增的複雜 seed/fixture 邏輯缺少情境說明註解。

## 反例（不該報）
- Benchmark 結果只是作為"這個改動沒有造成明顯效能劣化"的佐證，不是選型的唯一依據，且該路徑本來就非熱點。
- 已經在 CodSpeed 或其他 CI 隔離環境下有多次、跨版本可比對的數據，PR 討論中也承認單機數字的局限性並據此保守決策（如維持原方案不換）。
- benchmark 依賴本來就正確放在 devDependencies，或該套件同時也在 runtime 用到，放 dependencies 合理。
- 針对已经很成熟、社区广泛验证过特性差异的选型（如众所周知 md5 比 sha512 快）用简单跑分佐证，且改动本身影响面很小、可逆成本低。

## 出處
- https://github.com/nestjs/nest/pull/11073#discussion_r1099095552
- https://github.com/nestjs/nest/pull/10825#discussion_r1093097648
- https://github.com/prisma/prisma/pull/29038#discussion_r2787175011
- https://github.com/prisma/prisma/pull/28954#discussion_r2647944619
- https://github.com/prisma/prisma/pull/18728#discussion_r1170021900
- https://github.com/prisma/prisma/pull/18305#discussion_r1139263592
- https://github.com/prisma/prisma/pull/6128#discussion_r595804989
