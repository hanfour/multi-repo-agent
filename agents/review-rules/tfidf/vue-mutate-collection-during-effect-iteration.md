---
id: vue-mutate-collection-during-effect-iteration
layer: vue
frameworks: ["@vue/reactivity@*", "vue@^3.0.0"]
severity_default: HIGH
---
## 觸發訊號
diff 中對 reactivity 相關的集合（`Dep`/`Set<ReactiveEffect>`、`EffectScope.effects`、`EffectScope.scopes`、`effect.deps`、`scope.cleanups`）直接用 `for...of`／索引式 `for` 迴圈迭代，迴圈本體會呼叫可能反過來新增或刪除同一集合成員的操作（`effect.stop()`、`scope.stop()`、`trigger()`/`triggerEffects()`、scheduler 執行、`effect.run()`、`track()`/`cleanupEffect()`），卻沒有事先把集合複製成快照（例如缺少 `const effects = [...dep]` 或 `this.effects.slice()`，而是直接 `for (const effect of dep.keys())` 或 `for (i = 0; i < this.effects.length; i++) this.effects[i].stop()`）。

## 判準
`ReactiveEffect.stop()`／scheduler 執行時經常會從同一個 Set/Array 裡把自己（或巢狀建立的新 effect）加入或移除（例如 `stop()` 觸發 `cleanupEffect` 把自己從 `dep` 移除，或 effect 執行中建立新的 watcher 並 push 進同一個 `scope.effects`）。若直接在原始集合上迭代，迭代中途發生的增刪會造成索引錯位、部分 effect 被跳過未執行 `stop`/未被觸發，且不會拋出例外，只會安靜地漏執行——多半只有巢狀 effect／多 watcher 情境才會暴露，單一 effect 的測試測不出來，容易造成記憶體洩漏（effect 未被正確 dispose）或該更新的畫面沒更新。

## 嚴重度
CRITICAL：迭代刪改同一集合會造成生產路徑資料不一致（watcher 沒被觸發、或 effect 持續增長無上限造成 leak），且沒有對應測試覆蓋巢狀/多 effect 情境。
HIGH：迴圈本體呼叫會刪改同一集合的操作（`stop`/`scheduler`/`track`/`trigger`），但未先做陣列快照複製就直接迭代原始集合。
MEDIUM：迴圈中呼叫的操作理論上可能改動集合，目前程式路徑「恰好」不會觸發（需要額外測試或註解佐證這個假設，否則後續重構容易踩雷）。

## 反例（不該報）
- 迭代前已用 `.slice()`／`[...dep]`／`new Set(effects)` 等方式建立快照，才在快照上迭代並呼叫可能刪改原集合的操作——這是正確寫法。
- 迴圈本體只做讀取（統計、列印、比較），不會新增或刪除同一集合的成員。
- 迭代對象本來就是一次性建立、迭代完即丟棄、不會被其他地方持有引用的暫時陣列/集合。

## 出處
- https://github.com/vuejs/vue/pull/9327#discussion_r248265293
- https://github.com/vuejs/vue/pull/9107#discussion_r236563128
- https://github.com/vuejs/vue/pull/9107#discussion_r236557261
- https://github.com/vuejs/vue/pull/4652#discussion_r124529047
- https://github.com/vuejs/vue/pull/4652#discussion_r124527167
- https://github.com/vuejs/core/pull/12373#discussion_r1842370166
- https://github.com/vuejs/core/pull/12373#discussion_r1840823553
- https://github.com/vuejs/core/pull/12373#discussion_r1839578712
- https://github.com/vuejs/core/pull/6355#discussion_r1810293092
- https://github.com/vuejs/core/pull/5806#discussion_r1714838594
- https://github.com/vuejs/core/pull/5806#discussion_r1696938267
- https://github.com/vuejs/core/pull/7328#discussion_r1693506336
- https://github.com/vuejs/core/pull/11145#discussion_r1641231119
- https://github.com/vuejs/core/pull/11145#discussion_r1641228462
- https://github.com/vuejs/core/pull/7297#discussion_r1616401883
- https://github.com/vuejs/core/pull/10367#discussion_r1508834987
- https://github.com/vuejs/core/pull/10367#discussion_r1508819435
- https://github.com/vuejs/core/pull/10367#discussion_r1495750821
- https://github.com/vuejs/core/pull/9651#discussion_r1448755735
- https://github.com/vuejs/core/pull/9651#discussion_r1448721407
- https://github.com/vuejs/core/pull/9651#discussion_r1448720291
- https://github.com/vuejs/core/pull/9651#discussion_r1423825890
- https://github.com/vuejs/core/pull/9651#discussion_r1423715605
- https://github.com/vuejs/core/pull/9651#discussion_r1423697271
- https://github.com/vuejs/core/pull/9651#discussion_r1411773769
- https://github.com/vuejs/core/pull/9651#discussion_r1400434348
- https://github.com/vuejs/core/pull/9651#discussion_r1400432868
- https://github.com/vuejs/core/pull/9651#discussion_r1400431888
- https://github.com/vuejs/core/pull/9206#discussion_r1391933179
- https://github.com/vuejs/core/pull/9206#discussion_r1391259010
- https://github.com/vuejs/core/pull/9206#discussion_r1388737954
- https://github.com/vuejs/core/pull/9206#discussion_r1388727165
- https://github.com/vuejs/core/pull/5912#discussion_r1371182911
- https://github.com/vuejs/core/pull/9081#discussion_r1335148132
- https://github.com/vuejs/core/pull/9081#discussion_r1333952888
- https://github.com/vuejs/core/pull/8718#discussion_r1299182110
- https://github.com/vuejs/core/pull/7827#discussion_r1125595312
- https://github.com/vuejs/core/pull/7827#discussion_r1125594723
- https://github.com/vuejs/core/pull/7827#discussion_r1125594039
- https://github.com/vuejs/core/pull/4836#discussion_r1103623836
- https://github.com/vuejs/core/pull/4836#discussion_r1098302443
- https://github.com/vuejs/core/pull/4836#discussion_r1096840783
- https://github.com/vuejs/core/pull/4836#discussion_r1090417575
- https://github.com/vuejs/core/pull/4836#discussion_r1089590799
- https://github.com/vuejs/core/pull/4836#discussion_r1088769874
- https://github.com/vuejs/core/pull/4836#discussion_r1088767464
- https://github.com/vuejs/core/pull/4836#discussion_r1088764714
- https://github.com/vuejs/core/pull/5695#discussion_r850247932
- https://github.com/vuejs/core/pull/5575#discussion_r833078109
- https://github.com/vuejs/core/pull/5575#discussion_r830475380
- https://github.com/vuejs/core/pull/5575#discussion_r830218205
- https://github.com/vuejs/core/pull/4239#discussion_r681589917
- https://github.com/vuejs/core/pull/4239#discussion_r681568018
- https://github.com/vuejs/core/pull/4239#discussion_r681556003
- https://github.com/vuejs/core/pull/3377#discussion_r592465070
- https://github.com/vuejs/core/pull/3377#discussion_r592463221
- https://github.com/vuejs/core/pull/3377#discussion_r592430213
- https://github.com/vuejs/core/pull/2908#discussion_r549688923
- https://github.com/vuejs/core/pull/2195#discussion_r497121687
- https://github.com/vuejs/core/pull/1900#discussion_r474840535
- https://github.com/vuejs/core/pull/1900#discussion_r474050847
- https://github.com/vuejs/core/pull/1900#discussion_r473370057
- https://github.com/vuejs/core/pull/1900#discussion_r473341900
- https://github.com/vuejs/core/pull/330#discussion_r336450233
- https://github.com/vuejs/core/pull/286#discussion_r335017495
- https://github.com/vuejs/core/pull/286#discussion_r334761620
- https://github.com/vuejs/core/pull/286#discussion_r334746338
- https://github.com/vuejs/core/pull/99#discussion_r331749057
