---
id: rails-ensure-restores-hardcoded-not-original-state
layer: rails
frameworks: ["activerecord@>=5", "actionsupport@>=5"]
severity_default: HIGH

---
## 觸發訊號
diff 中出現方法開頭 mutate 一個共享/thread-local/singleton 旗標或狀態（例如 `@prevent_writes`、`Thread.current[:xxx]`、`@isolation_level`、connection pool 的 `@owner`/`@idle_since`、`IsolatedExecutionState` 相關值），並在 `ensure`（或等效的 finally/回復邏輯）中直接寫回一個字面量或預設值（如 `false`、`nil`、`:default`）而不是先在方法開頭把呼叫前的原始值存進區域變數、結束時再還原成那個變數。也包含把既有的 `original = self.attr; ...; ensure; self.attr = original` pattern 改成硬編碼還原值的 diff。

## 判準
這類旗標在 ActiveRecord/ActiveSupport 裡經常被巢狀呼叫（例如 `while_preventing_writes` 巢狀、`connected_to(role:)` 巢狀切換、transaction isolation 巢狀開啟）。若 `ensure` 直接寫回硬編碼值，會把外層呼叫設定的狀態一併抹除：外層明明設定了 `prevent_writes = true`，內層方法一返回就被強制設回 `false`，即使外層區塊還沒結束。這種 bug 在單元測試裡很難被抓到，因為多數測試只覆蓋單層呼叫，不會刻意巢狀呼叫來驗證還原邏輯，通常要等到 production 出現非預期寫入或交易狀態錯亂才會被發現。

## 嚴重度
CRITICAL：被硬編碼覆蓋的是資料庫寫入保護（如 `prevent_writes`）、connection owner、或交易隔離等級這類直接影響資料正確性/安全性的旗標，且該旗標的呼叫路徑可能被巢狀使用。
HIGH：被覆蓋的是一般 thread-local/singleton 狀態，會影響巢狀呼叫下游行為正確性，但不直接觸及資料寫入安全。
MEDIUM：僅影響測試輔助、debug 用途或生命週期內只會被設定一次（實務上不會巢狀）的旗標。

## 反例（不該報）
- 文件或介面已明確聲明該方法/旗標不支援巢狀呼叫，且目前程式庫中沒有任何呼叫點會巢狀使用它。
- 還原邏輯本來就正確地先存原始值再還原（`original = self.attr; ...; ensure; self.attr = original`），只是變數命名或位置有調整。
- 該旗標的預設值本身就是唯一合法值（例如僅在物件初始化時設定一次，且該物件不會重複進入這段程式碼路徑）。
- 因為要修正巢狀行為的 bug 而刻意改成硬編碼重置（即這正是修 bug 的本意，且已有對應測試涵蓋新行為），此時不該報為新問題。

## 出處
- https://github.com/rails/rails/pull/58060#discussion_r3692752166
- https://github.com/rails/rails/pull/57602#discussion_r3438258770
- https://github.com/rails/rails/pull/56695#discussion_r2741489054
- https://github.com/rails/rails/pull/56227#discussion_r2560942923
- https://github.com/rails/rails/pull/55902#discussion_r2440922913
- https://github.com/rails/rails/pull/55736#discussion_r2378478462
- https://github.com/rails/rails/pull/55722#discussion_r2366003136
- https://github.com/rails/rails/pull/55549#discussion_r2319898333
- https://github.com/rails/rails/pull/55549#discussion_r2309756110
- https://github.com/rails/rails/pull/55487#discussion_r2281259281
- https://github.com/rails/rails/pull/54836#discussion_r2020989923
- https://github.com/rails/rails/pull/54788#discussion_r2006592814
- https://github.com/rails/rails/pull/54738#discussion_r1991246563
- https://github.com/rails/rails/pull/54175#discussion_r1971829197
- https://github.com/rails/rails/pull/54175#discussion_r1962147518
- https://github.com/rails/rails/pull/53945#discussion_r1885015436
- https://github.com/rails/rails/pull/53139#discussion_r1783198425
- https://github.com/rails/rails/pull/52792#discussion_r1747387797
- https://github.com/rails/rails/pull/50371#discussion_r1692616681
- https://github.com/rails/rails/pull/52368#discussion_r1684852466
- https://github.com/rails/rails/pull/52298#discussion_r1679833173
- https://github.com/rails/rails/pull/50371#discussion_r1668384195
- https://github.com/rails/rails/pull/51958#discussion_r1621349297
- https://github.com/rails/rails/pull/51878#discussion_r1609041420
- https://github.com/rails/rails/pull/50979#discussion_r1588255190
- https://github.com/rails/rails/pull/51192#discussion_r1506037129
- https://github.com/rails/rails/pull/51083#discussion_r1497098366
- https://github.com/rails/rails/pull/50793#discussion_r1457755552
- https://github.com/rails/rails/pull/49378#discussion_r1339717832
- https://github.com/rails/rails/pull/47522#discussion_r1120192785
- https://github.com/rails/rails/pull/46690#discussion_r1065976157
- https://github.com/rails/rails/pull/46739#discussion_r1049865955
- https://github.com/rails/rails/pull/46399#discussion_r1013393648
- https://github.com/rails/rails/pull/45450#discussion_r909685088
- https://github.com/rails/rails/pull/45450#discussion_r905703998
- https://github.com/rails/rails/pull/45346#discussion_r898383138
- https://github.com/rails/rails/pull/45161#discussion_r882942534
- https://github.com/rails/rails/pull/44956#discussion_r862372652
- https://github.com/rails/rails/pull/44576#discussion_r839528791
- https://github.com/rails/rails/pull/44127#discussion_r829259484
- https://github.com/rails/rails/pull/44576#discussion_r822476418
- https://github.com/rails/rails/pull/44219#discussion_r795960628
- https://github.com/rails/rails/pull/44219#discussion_r789191059
- https://github.com/rails/rails/pull/43596#discussion_r746050117
- https://github.com/rails/rails/pull/43485#discussion_r731052419
- https://github.com/rails/rails/pull/42572#discussion_r658705259
- https://github.com/rails/rails/pull/42475#discussion_r651228459
- https://github.com/rails/rails/pull/41495#discussion_r580113622
- https://github.com/rails/rails/pull/41408#discussion_r574601459
- https://github.com/rails/rails/pull/40037#discussion_r570556112
- https://github.com/rails/rails/pull/40742#discussion_r535584742
- https://github.com/rails/rails/pull/40576#discussion_r519530198
- https://github.com/rails/rails/pull/40531#discussion_r516989018
- https://github.com/rails/rails/pull/40133#discussion_r495500158
- https://github.com/rails/rails/pull/39133#discussion_r419417586
- https://github.com/rails/rails/pull/38449#discussion_r382033742
- https://github.com/rails/rails/pull/37393#discussion_r370959211
- https://github.com/rails/rails/pull/37723#discussion_r346696324
- https://github.com/rails/rails/pull/37388#discussion_r338229636
- https://github.com/rails/rails/pull/37002#discussion_r316424853
- https://github.com/rails/rails/pull/36711#discussion_r305341154
- https://github.com/rails/rails/pull/36469#discussion_r293085999
- https://github.com/rails/rails/pull/36416#discussion_r291636418
- https://github.com/rails/rails/pull/35623#discussion_r266246229
- https://github.com/rails/rails/pull/35089#discussion_r252311515
- https://github.com/rails/rails/pull/34773#discussion_r252124180
- https://github.com/rails/rails/pull/34632#discussion_r239803456
- https://github.com/rails/rails/pull/34052#discussion_r222057868
- https://github.com/rails/rails/pull/32647#discussion_r209650345
- https://github.com/rails/rails/pull/33337#discussion_r202035310
- https://github.com/rails/rails/pull/33054#discussion_r195787536
- https://github.com/rails/rails/pull/32058#discussion_r170423984
- https://github.com/rails/rails/pull/31422#discussion_r156730980
- https://github.com/rails/rails/pull/31323#discussion_r154542731
- https://github.com/rails/rails/pull/31173#discussion_r151823414
- https://github.com/rails/rails/pull/21020#discussion_r105083853
- https://github.com/rails/rails/pull/28207#discussion_r104130031
- https://github.com/rails/rails/pull/26672#discussion_r81396598
- https://github.com/rails/rails/pull/25717#discussion_r69738911
- https://github.com/rails/rails/pull/24897#discussion_r62423075
- https://github.com/rails/rails/pull/24764#discussion_r61386979
- https://github.com/rails/rails/pull/24493#discussion_r59145853
- https://github.com/rails/rails/pull/21883#discussion_r42056882
- https://github.com/rails/rails/pull/21320#discussion_r37670211
- https://github.com/rails/rails/pull/18200#discussion_r25780776
- https://github.com/rails/rails/pull/18928#discussion_r24683116
- https://github.com/rails/rails/pull/14938#discussion_r16330695
- https://github.com/rails/rails/pull/15394#discussion_r13655029
- https://github.com/rails/rails/pull/15380#discussion_r13133407
- https://github.com/rails/rails/pull/14843#discussion_r11892448
- https://github.com/rails/rails/pull/14400#discussion_r10692905
- https://github.com/rails/rails/pull/10939#discussion_r6179466
- https://github.com/rails/rails/pull/10156#discussion_r3725957
- https://github.com/rails/rails/pull/7546#discussion_r1547286
- https://github.com/rails/rails/pull/5344#discussion_r536906
