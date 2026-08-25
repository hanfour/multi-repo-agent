---
id: rails-framework-semantics-implicit-behavior-change
layer: rails
frameworks: ["rails@*"]
severity_default: HIGH

---
## 觸發訊號
diff 中出現以下任一種變更時，去確認「這是否改變了現有呼叫者已經依賴的行為」：
- 修改一個既有 public 方法（簽章不變）的內部邏輯、條件分支、預設值計算、或回傳值組成方式，而不是新增方法
- 簡化、合併或重寫一段既有的條件判斷式（if/case/正則），使某些既有輸入落入跟修改前不同的分支
- 修改一個被多個 public API 共用的私有/內部 helper（例如集合操作、參數正規化、型別轉換），因為改動會擴散到所有呼叫端
- 改變參數合併/覆寫的順序，或改變某個選項在「未傳入」與「傳入 nil / false」時的處理方式
- 替換底層依賴呼叫（例如 `Tempfile.open` → `Tempfile.create`、regex 引擎、gsub → chomp）且語意上被當作等價

出現以上任一情況時，要去對照：這個變更前後，對同一組既有輸入，輸出/副作用是否不同？如果不同，PR 裡有沒有為此新增測試、CHANGELOG 條目、deprecation warning 或至少在 PR 描述中承認這是 behavior change？

## 判準
Rails 是被大量下游應用直接依賴的框架，任何隱性行為改變都可能是無聲的 breaking change——即使新程式碼本身邏輯正確、測試全綠，因為既有測試套件通常只覆蓋作者當初設計的路徑，不會涵蓋所有實際依賴該行為的下游用法。資深 reviewer（如 rafaelfranca、byroot、kamipo、jonathanhefner）在讀這類 diff 時的直覺反應幾乎都是「這樣會不會讓某個原本可行的用法變得不同」，而這件事無法只看被改的那幾行程式碼判斷，必須主動重建呼叫端的心智模型、回想語言/函式庫本身的既有語意，才抓得到。這正是 reviewer 目前最大的盲區：漏抓的問題不是寫錯了什麼，而是沒有意識到「這裡其實動到了一個既有契約」。

## 嚴重度
CRITICAL：改動的是穩定的 public API（含被廣泛使用的 helper/中介層），沒有 deprecation path，也沒有新增測試涵蓋舊行為使用者會踩到的情境，可能大範圍且無聲地破壞現有應用（例如：讓沒設定 scope 的既有呼叫共用同一個 rate limit bucket、讓 collection proxy 對未持久化紀錄的行為悄悄改變）
HIGH：改動的是內部共用邏輯，影響範圍可預期但較侷限，部分測試已覆蓋新行為，但沒有對照說明舊行為的使用者是否受影響，也沒有 CHANGELOG 更新
MEDIUM：行為改變侷限在明確的邊界情況（例如特定型別的參數、字串邊界空白、特殊字元），且已有對應測試，但 PR 沒有解釋為何確定這個改變是安全的

## 反例（不該報）
- 純新增的方法、選項或參數，且未傳入時完全不影響既有呼叫路徑
- 修正的是明確的 bug（既有行為本身會噴錯、回傳錯誤結果，或違反文件所述行為），把它修回文件承諾的行為不算引入新的行為改變
- 已經規劃好 deprecation warning 與 migration 路徑、並在 PR 中明確說明的漸進式行為變更
- 只影響測試檔案內部 helper 或測試專用程式碼，不涉及任何 production 執行路徑
- 修改的是尚未發布、仍在同一個 PR 內新增的程式碼，還沒有任何外部呼叫者可能依賴其行為

## 出處
- https://github.com/rails/rails/pull/57070#discussion_r3000014784
- https://github.com/rails/rails/pull/53449#discussion_r2271017009
- https://github.com/rails/rails/pull/53920#discussion_r1904580895
- https://github.com/rails/rails/pull/45399#discussion_r1575321643
- https://github.com/rails/rails/pull/49990#discussion_r1491776652
- https://github.com/rails/rails/pull/49677#discussion_r1364264898
- https://github.com/rails/rails/pull/46626#discussion_r1190326107
- https://github.com/rails/rails/pull/46652#discussion_r1043403115
- https://github.com/rails/rails/pull/46639#discussion_r1043183393
- https://github.com/rails/rails/pull/45942#discussion_r962447857
- https://github.com/rails/rails/pull/45346#discussion_r898400689
- https://github.com/rails/rails/pull/43766#discussion_r761560258
- https://github.com/rails/rails/pull/43539#discussion_r739670961
- https://github.com/rails/rails/pull/41994#discussion_r637614006
- https://github.com/rails/rails/pull/41084#discussion_r625216521
- https://github.com/rails/rails/pull/41313#discussion_r568977313
- https://github.com/rails/rails/pull/41144#discussion_r561369458
- https://github.com/rails/rails/pull/39929#discussion_r517666451
- https://github.com/rails/rails/pull/38763#discussion_r394605066
- https://github.com/rails/rails/pull/35451#discussion_r360418226
- https://github.com/rails/rails/pull/37296#discussion_r329740734
- https://github.com/rails/rails/pull/46846#discussion_r1064004905
