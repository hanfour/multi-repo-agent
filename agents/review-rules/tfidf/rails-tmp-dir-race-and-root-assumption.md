---
id: rails-tmp-dir-race-and-root-assumption
layer: rails
frameworks: ["rails@>=4.0"]
severity_default: MEDIUM

---
## 觸發訊號
diff 出現操作 `tmp/`（或其他執行期產生的目錄，如 restart.txt、sockets、cache、storage 所在目錄）的程式碼，且符合下列任一模式：
- `unless File.directory?(dir)` / `unless Dir.exist?(dir)` 後面接 `Dir.mkdir` 或不帶 `_p` 的 `FileUtils.mkdir`，而非直接呼叫 `FileUtils.mkdir_p`。
- railties 的 command/rake task（例如 `restart`、`spawn_console`）直接用相對路徑字串（`"tmp"`、`"tmp/restart.txt"`）操作檔案，卻沒有先解出穩定的 app root（`Rails.root` 或 `Rails::Command.root`），隱含假設目前 CWD 就是 app 根目錄。
- 測試 teardown 裡出現 `FileUtils.remove_entry(@ivar) if @ivar` 這種條件式清理，但對應的 `@ivar` 其實在 `setup` 裡無條件被賦值（條件式是死碼，掩蓋了「這個資源其實一定存在」的事實）。

## 判準
- exist-check 再 create 之間存在 TOCTOU 競態：兩個 process（例如 web server 收到多個並發 request 都觸發 restart）同時看到目錄不存在，兩者都嘗試 `mkdir`，其中一個會因 `Errno::EEXIST` 而未預期地中斷。`FileUtils.mkdir_p` 本身是 idempotent、目錄已存在時不會報錯，直接取代整段 check-then-create 邏輯更安全也更簡短。
- 用相對路徑假設 CWD 是 app root，在「從 app 目錄外呼叫 `bin/rails`」或「透過 `BUNDLE_GEMFILE=... bin/rails`」等常見情境下會找錯目錄，輕則靜默失敗（例如新版行為是找不到 Rakefile 時不報錯，直接沒反應），重則對別的目錄動手（在非預期路徑 mkdir/touch）。
- 死碼式的條件清理（`if @ivar` 但 `@ivar` 一定被設置）會讓下一位維護者誤以為那個資源是「可能不存在」的，增加理解成本，也可能在真正條件性建立資源時（例如把建立邏輯搬到別的 helper）悄悄掩蓋沒清理到的 bug。

## 嚴重度
CRITICAL：出現在會被多個 process/request 併發觸發的路徑（例如 server 內建的 restart 機制），競態會拋出未捕捉例外造成服務中斷，且沒有任何 retry/lock 保護。
HIGH：CLI command 或 rake task 用相對路徑假設 CWD 為 app root、且沒有回退到 `Rails.root`/`Command.root`，會在常見的「從外部目錄呼叫 bin/rails」情境下操作錯誤路徑或靜默失敗，且無測試覆蓋此情境。
MEDIUM：測試輔助程式碼或本機開發工具中出現同樣的 race-prone mkdir 寫法、或死碼式條件清理，並發或誤導維護者的機率低，但仍是不必要的複雜度、應該用更直接的寫法（`mkdir_p`、無條件清理）取代。

## 反例（不該報）
- 直接呼叫 `FileUtils.mkdir_p(dir)`（不先做 exist 檢查）— 這本來就是正確寫法，不該報。
- 目錄建立與刪除全部發生在同一支單執行緒的 test setup/teardown 內、依序執行、沒有跨 process 併發可能時，不算 CRITICAL/HIGH（頂多算 MEDIUM 的程式碼簡化建議），因為不存在真正的競態風險。
- 在 mkdir 前已經有 mutex/檔案鎖或其他互斥機制保護時，不算此規則要抓的問題。
- Command 明確且有意地要操作「目前所在目錄」而非 app root（例如某些 debug 用的臨時腳本），並在文件/desc 中說明此假設時，不必因為用了相對路徑就報。

## 出處
- https://github.com/rails/rails/pull/52045#discussion_r1631325036
- https://github.com/rails/rails/pull/47698#discussion_r1141007670
- https://github.com/rails/rails/pull/47619#discussion_r1141007670
- https://github.com/rails/rails/pull/47619#discussion_r1135168409
- https://github.com/rails/rails/pull/47619#discussion_r1133327345
- https://github.com/rails/rails/pull/20300#discussion_r31014598
- https://github.com/rails/rails/pull/13116#discussion_r8014394
- https://github.com/rails/rails/pull/7586#discussion_r1566497
