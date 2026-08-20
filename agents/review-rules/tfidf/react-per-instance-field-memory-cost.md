---
id: react-per-instance-field-memory-cost
layer: react
frameworks: ["react@*"]
severity_default: MEDIUM
---
## 觸發訊號
diff 在 renderer host config 或其配套的 per-node host instance 型別（例如 `ReactFabricHostComponent`、`ReactNativeFiberHostComponent`，或是 `createInstance`/`createTextInstance` 回傳的 instance 物件字面量）中，新增一個欄位／屬性，且該欄位：
- 在 constructor 或建立時無條件賦值（即使初始值是 `null`）；
- 只被少數功能（如 event responder、view transition、debug tooling）使用，多數情況下用不到；
- 沒有包在 `__DEV__` 判斷式裡，也沒有 lazy init，也沒有改用 WeakMap／外部 side table 之類「按需付費」的做法。

## 判準
Host instance 是每個渲染出來的 DOM／native 節點都會建立一份，一棵樹可能有成千上萬個。任何新增欄位——即使只是一個 `null` pointer——都會在整棵樹上乘以節點數，永久墊高 baseline 記憶體用量，即使該值在絕大多數情況下根本用不到。resident React 團隊在多次 review 中要求：這類欄位要嘛限定在 `__DEV__`、嘛 lazy 初始化、嘛移到 fiber 對應的外部 WeakMap，而不是無條件塞進每個 instance。

## 嚴重度
CRITICAL：（此規則本身不構成 CRITICAL）
HIGH：欄位加在高頻／通用的 host instance 型別（例如 base HostComponent）上，沒有 DEV gate、沒有 lazy init，PR 也沒說明為何可接受記憶體增加
MEDIUM：欄位只服務於少數／opt-in 功能（如 event responder、view transition），理論上可以用 `__DEV__` 或既有 feature flag 包起來，或延後到真正需要時才初始化
LOW：純命名／位置調整，或該欄位是 1:1 取代既有同大小欄位、沒有淨增加記憶體

## 反例（不該報）
- 欄位加在本來就只在 DEV/debug tooling 使用的型別上（例如 react-devtools-shared 的 instance 型別）；
- 欄位是 1:1 取代既有欄位，沒有淨增加大小；
- 欄位加在每個 root 才建立一次的 config/options 物件上，而非每個節點都建立一份的 instance；
- PR 已經明確用 `if (__DEV__)` 包住新欄位。

## 出處
- https://github.com/react/react/pull/35764#discussion_r2962221633
- https://github.com/react/react/pull/35764#discussion_r2854998252
- https://github.com/react/react/pull/33064#discussion_r2074034222
- https://github.com/react/react/pull/30865#discussion_r1744330830
- https://github.com/react/react/pull/28169#discussion_r1477247561
- https://github.com/react/react/pull/26735#discussion_r1181815595
- https://github.com/react/react/pull/26698#discussion_r1174240062
- https://github.com/react/react/pull/26321#discussion_r1138955085
- https://github.com/react/react/pull/26332#discussion_r1129154173
- https://github.com/react/react/pull/26303#discussion_r1125404470
- https://github.com/react/react/pull/25559#discussion_r1006313355
- https://github.com/react/react/pull/25426#discussion_r990198575
- https://github.com/react/react/pull/25010#discussion_r933871458
- https://github.com/react/react/pull/24496#discussion_r865509261
- https://github.com/react/react/pull/24311#discussion_r846073197
- https://github.com/react/react/pull/23278#discussion_r814438490
- https://github.com/react/react/pull/22887#discussion_r768236542
- https://github.com/react/react/pull/18814#discussion_r419518695
- https://github.com/react/react/pull/18730#discussion_r416818981
- https://github.com/react/react/pull/18730#discussion_r416797328
- https://github.com/react/react/pull/18668#discussion_r411479349
- https://github.com/react/react/pull/18609#discussion_r408342511
- https://github.com/react/react/pull/18388#discussion_r400428864
- https://github.com/react/react/pull/18388#discussion_r400285845
- https://github.com/react/react/pull/18292#discussion_r391873576
- https://github.com/react/react/pull/17225#discussion_r341299626
- https://github.com/react/react/pull/16540#discussion_r316908219
- https://github.com/react/react/pull/15998#discussion_r310808754
- https://github.com/react/react/pull/16205#discussion_r307368348
- https://github.com/react/react/pull/15504#discussion_r283480567
- https://github.com/react/react/pull/15308#discussion_r272218801
- https://github.com/react/react/pull/15151#discussion_r271058962
- https://github.com/react/react/pull/15261#discussion_r270962751
- https://github.com/react/react/pull/15179#discussion_r268936826
- https://github.com/react/react/pull/15112#discussion_r266732818
- https://github.com/react/react/pull/15112#discussion_r265841597
- https://github.com/react/react/pull/14596#discussion_r248008730
- https://github.com/react/react/pull/14382#discussion_r239226071
- https://github.com/react/react/pull/14115#discussion_r230943307
- https://github.com/react/react/pull/13279#discussion_r205807222
- https://github.com/react/react/pull/12766#discussion_r187650740
- https://github.com/react/react/pull/12766#discussion_r186806435
- https://github.com/react/react/pull/12505#discussion_r178483871
- https://github.com/react/react/pull/11927#discussion_r160012871
- https://github.com/react/react/pull/11232#discussion_r145279245
- https://github.com/react/react/pull/11232#discussion_r144969841
- https://github.com/react/react/pull/11232#discussion_r144894372
- https://github.com/react/react/pull/11225#discussion_r144684695
- https://github.com/react/react/pull/11072#discussion_r142514928
- https://github.com/react/react/pull/11044#discussion_r142273569
- https://github.com/react/react/pull/10624#discussion_r137425860
- https://github.com/react/react/pull/10210#discussion_r128351189
- https://github.com/react/react/pull/10210#discussion_r128121490
- https://github.com/react/react/pull/10056#discussion_r124415896
- https://github.com/react/react/pull/9076#discussion_r103535513
- https://github.com/react/react/pull/8634#discussion_r95492136
- https://github.com/react/react/pull/8688#discussion_r94675985
- https://github.com/react/react/pull/8634#discussion_r94154477
- https://github.com/react/react/pull/8586#discussion_r93822624
- https://github.com/react/react/pull/8584#discussion_r93124237
- https://github.com/react/react/pull/7089#discussion_r67761250
- https://github.com/react/react/pull/6400#discussion_r58781233
- https://github.com/react/react/pull/3842#discussion_r30014213
- https://github.com/react/react/pull/3640#discussion_r28108028
- https://github.com/react/react/pull/2065#discussion_r25392020
- https://github.com/react/react/pull/2065#discussion_r16514505
