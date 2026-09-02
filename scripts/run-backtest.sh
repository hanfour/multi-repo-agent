#!/usr/bin/env bash
# 對基準集跑一輪 review 並算出三個指標。
#
# 不 post 到 PR。每個 PR 的 review 輸出各存一個檔，彙總存 summary.json，
# 讓新舊規則可以用 --compare 直接比。
#
# 沒有任何 confirmed==true 的基準時直接退出非 0。輸出一份 0 筆的 summary 會讓人
# 以為跑過了，那正是 2026-06-23 false-green 的形狀。
#
# 彙總指標的算法是「先把所有已跑成功的 PR 的 match／comment 攤平成兩個陣列，
# 最後只呼叫一次 backtest_metrics」，不是「每個 PR 各自算一次指標再平均」。
# 後者會讓只有 1 筆 expected finding 的 PR 跟有 10 筆的 PR 在平均時權重相同，
# 一個異常值就能把整體數字帶偏；前者天生照筆數加權，才符合「這組數字要拿來
# 跟階段四的新規則比」的用途。
#
# summary.json 一定走 tmp→mv 兩段式：算出的 JSON 先落到同目錄的 .tmp、驗過
# jq 與 mv 兩邊的退出碼才算數，任一邊失敗都用各自的 token 分開報。直接寫
# （不走這道 tmp→mv）一旦寫到一半失敗，會在原地留下一個殘破或被截斷的
# summary.json；--compare 讀到的是假數字，而不是一個明確的失敗，比殘破檔案
# 本身更危險。
set -uo pipefail

MRA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$MRA_DIR/lib/backtest-metrics.sh"
# repo 屬於哪一層（分層 persona 用，見下面 MRA_PERSONAS_ROOT 的說明）。
source "$MRA_DIR/lib/corpus-internal.sh"

BENCH_DIR="${MRA_BENCHMARK_DIR:-$HOME/.cache/mra-review-benchmark}"
C="$BENCH_DIR/candidates.json"
MRA_CMD="${MRA_BACKTEST_CMD:-$MRA_DIR/bin/mra.sh}"

# 彙總結果一定走這裡：算出的 JSON 先落到同目錄的 .tmp，驗過退出碼才 mv
# promote 進正式檔名，mv 也要驗退出碼。任何一步失敗都不動 $out_file，
# 只清掉沒搬成功的 .tmp——寫入失敗與搬移失敗要用各自的 token 分開報，不能
# 混報成同一句話，不然沒辦法分辨是「這次算出來的內容有問題」還是「搬檔案
# 這步本身失敗」。
#
# $1：要寫入的正式檔名。$2 之後：整段傳給 `jq -n` 的參數（含 filter 本身）。
_write_summary() {
  local out_file="$1" tmp
  shift
  tmp="${out_file}.tmp"
  if ! jq -n "$@" > "$tmp"; then
    echo "SUMMARY_WRITE_FAILED：彙總 ${out_file} 失敗，${out_file} 未變動" >&2
    rm -f "$tmp"
    return 1
  fi
  if ! mv "$tmp" "$out_file"; then
    echo "SUMMARY_PROMOTE_FAILED：搬移彙總結果到 ${out_file} 失敗，${out_file} 未變動" >&2
    rm -f "$tmp"
    return 1
  fi
  return 0
}

case "${1:-}" in
  --compare)
    LABEL_A="${2:-}"; LABEL_B="${3:-}"
    [[ -n "$LABEL_A" && -n "$LABEL_B" ]] || {
      echo "用法：run-backtest.sh --compare <label_a> <label_b>" >&2; exit 1; }
    # 兩個 label 一樣就是同一份 summary.json 硬比自己：印出來的兩欄一定
    # 一模一樣，看起來像「新舊沒差別」，但其實根本沒比到東西，多半是打錯其中
    # 一個 label。與其印一份沒有資訊量、還可能被誤讀成「真的沒差」的表，不如
    # 直接擋下來讓使用者發現打錯了。
    [[ "$LABEL_A" != "$LABEL_B" ]] || {
      echo "SAME_LABEL：--compare 的兩個 label 都是 ${LABEL_A}，沒有東西可比" >&2; exit 1; }
    SUM_A="$BENCH_DIR/runs/$LABEL_A/summary.json"
    SUM_B="$BENCH_DIR/runs/$LABEL_B/summary.json"
    for f in "$SUM_A" "$SUM_B"; do
      [[ -f "$f" ]] || { echo "找不到 ${f}" >&2; exit 1; }
    done
    # 兩份各自讀一次就好，之後每個指標鍵都從記憶體裡的內容取值——這樣才能
    # 保證 A 欄一定來自 $SUM_A、B 欄一定來自 $SUM_B，不會因為共用同一個
    # 變數、或漏改其中一次呼叫的檔名，讓兩欄印出同一份資料。
    JSON_A="$(cat "$SUM_A")" || { echo "READ_FAILED：讀取 ${SUM_A} 失敗" >&2; exit 1; }
    JSON_B="$(cat "$SUM_B")" || { echo "READ_FAILED：讀取 ${SUM_B} 失敗" >&2; exit 1; }
    # 壞掉的 summary.json（存在但不是合法 JSON）在這裡一次擋下來，用自己的
    # token 給乾淨診斷——不要放給下面逐鍵解析時才失敗，那樣使用者看到的會是
    # jq 自己吐的 parse error（一長串看起來像 stack trace 的訊息），而不是
    # 一句講得清楚「哪個檔案壞掉」的話。
    jq -e . >/dev/null 2>&1 <<<"$JSON_A" || {
      echo "SUMMARY_MALFORMED：${SUM_A} 不是合法 JSON" >&2; exit 1; }
    jq -e . >/dev/null 2>&1 <<<"$JSON_B" || {
      echo "SUMMARY_MALFORMED：${SUM_B} 不是合法 JSON" >&2; exit 1; }
    # 容差不同的兩份 summary 不能比：三個率全部由它決定，同一批 review 輸出
    # 在 tol 5 與 tol 15 下可以是 miss_rate 1.0 對 0.0，看起來像完勝。這正是
    # summary.json 會記 tolerance 欄位的原因（見下面寫入處的說明），但
    # --compare 原本既不印也不檢查它。舊的 summary 沒有這個欄位，讀到 null
    # 時只警告不擋——擋下來會讓這個功能對階段二的既有資料完全不能用。
    TOL_A="$(jq -r '.tolerance // "null"' <<<"$JSON_A")"
    TOL_B="$(jq -r '.tolerance // "null"' <<<"$JSON_B")"
    if [[ "$TOL_A" != "$TOL_B" ]]; then
      echo "TOLERANCE_MISMATCH：${LABEL_A} 用容差 ${TOL_A}、${LABEL_B} 用容差 ${TOL_B}，三個指標全部由容差決定，這兩份數字不能直接比" >&2
      exit 1
    fi
    if [[ "$TOL_A" == "null" ]]; then
      echo "TOLERANCE_UNKNOWN：兩份 summary 都沒有記 tolerance（階段二之前的舊格式），無法確認它們用同一個容差算出來" >&2
    fi
    printf '%-18s %10s %10s\n' "指標" "$LABEL_A" "$LABEL_B"
    printf '%-18s %10s %10s\n' "tolerance" "$TOL_A" "$TOL_B"
    for k in expected_total missed miss_rate comments_total unmatched unmatched_rate severity_agree severity_rate; do
      VAL_A="$(printf '%s' "$JSON_A" | jq -r --arg k "$k" '.[$k]' 2>/dev/null)" ||
        { echo "READ_FAILED：解析 ${SUM_A} 失敗" >&2; exit 1; }
      VAL_B="$(printf '%s' "$JSON_B" | jq -r --arg k "$k" '.[$k]' 2>/dev/null)" ||
        { echo "READ_FAILED：解析 ${SUM_B} 失敗" >&2; exit 1; }
      printf '%-18s %10s %10s\n' "$k" "$VAL_A" "$VAL_B"
    done
    exit 0 ;;
esac

# --recompute：只拿已經存在的 review 輸出重算指標，一次 review 都不跑。
#
# 用途是「同一輪跑完之後換個容差再算一次」。沒有這個模式的話，那個動作會連帶
# 重跑所有失敗的 PR，而重跑會覆寫它們的 .err —— 實測過一次：兩筆 PR 原本的
# 失敗原因是 synthesize 輪數用盡，容差重算時 OAuth 剛好過期，.err 全被換成
# OAuth 錯誤，原本的診斷證據就此消失。重算容差不該有副作用。
LABEL=""; TOL=5; RECOMPUTE=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --label)
      [[ $# -ge 2 ]] || { echo "用法：--label 需要接一個值" >&2; exit 1; }
      LABEL="$2"; shift 2 ;;
    --tolerance)
      [[ $# -ge 2 ]] || { echo "用法：--tolerance 需要接一個值" >&2; exit 1; }
      TOL="$2"; shift 2 ;;
    --recompute)
      RECOMPUTE=1; shift ;;
    -h|--help)
      echo "用法: run-backtest.sh --label <名稱> [--tolerance N] [--recompute] | --compare <a> <b>"
      echo "  --recompute：只用已存在的 review 輸出重算指標，不跑任何 review"
      exit 0 ;;
    *) echo "未知參數：$1" >&2; exit 1 ;;
  esac
done
[[ -z "$LABEL" ]] && { echo "缺 --label" >&2; exit 1; }

# 容差必須是非負數。這一道要在這裡驗，不能只靠呼叫端：$TOL 一路傳到
# backtest_match 裡做 `距離 <= $tol` 的比較。jq 的型別排序是 null 小於任何
# 數字，所以 $tol 是 null 時這個比較恆為 false —— 每一條 expected 都不命中，
# 漏抓率變成完美的 1.0，不會有任何錯誤訊息。負值的結果一樣。
# 實測過：`backtest_match` 在 tolerance=null 與 -3 時都正常回傳 JSON，只是
# 全部不命中。那個 1.0 還會原樣寫進 summary.json，事後看不出它是垃圾。
if ! jq -n --argjson t "$TOL" -e '($t | type) == "number" and $t >= 0' >/dev/null 2>&1; then
  echo "TOLERANCE_INVALID：--tolerance 的值「${TOL}」不是非負數" >&2
  exit 1
fi

# 覆蓋率門檻同樣在開跑之前驗，不要等到幾小時的 review 全部跑完才報錯 —— 這支
# 腳本自己的原則就是「失敗要早、要響」。
#
# 驗的是「0 到 1 之間的數字」，不是「合法 JSON」。只驗後者的話 null 與 true
# 都會過，而 jq 的型別排序裡兩者都小於任何數字，底下的 `$c < $m` 恆為 false，
# 覆蓋率門檻被靜默關掉：10 筆 confirmed 只跑成 1 筆也照樣輸出 summary、退出碼
# 0。那正是這道門檻要防的東西。跟 --tolerance 同一個形狀。
MIN_COVERAGE="${MRA_BACKTEST_MIN_COVERAGE:-0.8}"
if ! jq -n --argjson m "$MIN_COVERAGE" -e \
     '($m | type) == "number" and $m >= 0 and $m <= 1' >/dev/null 2>&1; then
  echo "MIN_COVERAGE_INVALID：MRA_BACKTEST_MIN_COVERAGE=${MIN_COVERAGE} 不是 0 到 1 之間的數字" >&2
  exit 1
fi

[[ -f "$C" ]] || { echo "找不到 ${C}" >&2; exit 1; }

n_conf="$(jq '[.[] | select(.confirmed == true)] | length' "$C")" ||
  { echo "READ_FAILED：讀取 ${C} 失敗" >&2; exit 1; }
if [[ "$n_conf" -eq 0 ]]; then
  echo "NO_CONFIRMED：基準集裡沒有 confirmed==true 的 PR，先跑 scripts/review-benchmark.sh 完成人工確認" >&2
  exit 1
fi

# 有 confirmed 的 PR 不代表有 expected finding。`--set true` 做了、`--add` 還
# 沒做的話，n_conf 是正的但每一筆的 expected_findings 都是空陣列，跑出來的
# summary 會是 expected_total=0、三個率全部 0、退出碼 0 —— 一份看起來完美的
# 成績單，實際上什麼都沒量到。這跟開頭那個 NO_CONFIRMED 是同一種假象，只是
# 少了一層。
# 排除清單：經查證確認在受審 PR 當下不成立的 expected finding。
#
# 基準集是拿 fix commit 的 hunk 行號跟受審 PR 的改動範圍取交集產生的，交集
# 算得出行號不代表那裡有缺陷。實測 54 條裡有 34 條站不住：缺陷在受審當下
# 還不存在（後來的改動才讓它成立）、引用的行是未改動的 context（note 的
# 主體在檔案別處甚至別的檔案）、或 note 描述的缺陷根本不存在。這些條目
# 不管換什麼設定都會被算成漏抓，把每一輪的 file_miss_rate 都拉到同一個
# 區間，看起來像天花板。
#
# 刻意不改 candidates.json：candidates_effective_sha 涵蓋 confirmed==true
# 項目的 expected_findings，動它會讓既有 summary 的指紋全部對不上，那些輪
# 次就失去可比性。改用獨立清單，而且預設不套用——要明確設
# MRA_BACKTEST_APPLY_EXCLUSIONS=1 才生效，因為套用之後的數字跟先前的輪次
# 不是同一個分母，不該在使用者沒察覺的情況下換掉。
EXCL_FILE="${MRA_BACKTEST_EXCLUSIONS:-$BENCH_DIR/expected-exclusions.json}"
EXCLUSIONS='[]'
EXCLUSIONS_APPLIED=false
if [[ "${MRA_BACKTEST_APPLY_EXCLUSIONS:-0}" == "1" ]]; then
  EXCLUSIONS_APPLIED=true
  if [[ -s "$EXCL_FILE" ]]; then
    EXCLUSIONS="$(jq -c '.exclusions // []' "$EXCL_FILE")" || {
      echo "EXCLUSIONS_READ_FAILED：讀取 ${EXCL_FILE} 失敗，這一輪不套用排除" >&2
      EXCLUSIONS='[]'
    }
  else
    echo "EXCLUSIONS_MISSING：找不到 ${EXCL_FILE}，這一輪不排除任何條目" >&2
  fi
fi
excluded_count=0

n_findings="$(jq --argjson ex "$EXCLUSIONS" '
  [ .[] | select(.confirmed == true)
    | . as $c
    | .expected_findings
    | map(select(. as $ef
        | ($ex | any(.repo == $c.repo and .pr == $c.pr
                     and .path == $ef.path and .line == $ef.line)) | not))
    | length ] | add // 0' "$C")" ||
  { echo "READ_FAILED：讀取 ${C} 的 expected_findings 失敗" >&2; exit 1; }
if [[ "$n_findings" -eq 0 ]]; then
  echo "NO_EXPECTED_FINDINGS：${n_conf} 個 PR 標成 confirmed，但一條 expected finding 都沒有。用 scripts/review-benchmark.sh --add 補上，不然算出來的三個率全部是 0，看起來像滿分" >&2
  exit 1
fi

# (repo, pr) 是每個 PR 輸出檔的鍵，同一個鍵在 confirmed==true 裡出現兩次，
# 第二筆會直接讀到第一筆跑出來的快取檔、再算一次、再疊加進彙總——不是報錯，
# 是悄悄把同一個 PR 的 match／comment 多算一輪，把 expected_total、
# comments_total 等等全部墊高。這種數字錯得不明顯，比噴錯還危險，所以擋在
# 開始跑之前，不要留給重複計算自己去攤平。
dup_keys="$(jq -r '
  [.[] | select(.confirmed == true) | "\(.repo)#\(.pr)"]
  | group_by(.) | map(select(length > 1) | .[0]) | .[]' "$C")"
if [[ -n "$dup_keys" ]]; then
  echo "DUPLICATE_PR：基準集裡有重複的 confirmed PR：$(tr '\n' ' ' <<<"$dup_keys")" >&2
  exit 1
fi

# --- 分層 persona：依 repo 所屬層挑要載入哪一份注入後的 persona -------------
# MRA_PERSONAS_ROOT 指向 rule_inject_layers 的輸出根目錄（底下每層一個子目錄）。
# 設了它，這支腳本就逐 PR 依 repo 決定 MRA_PERSONAS_DIR；沒設就完全維持原本的
# 行為——整輪共用呼叫端給的 MRA_PERSONAS_DIR，或內建的 agents/personas。
#
# persona 目錄是 review 流程唯一的載入點（lib/personas.sh 的 _personas_dir()），
# 一次只能指向一個目錄，所以「Rails PR 讀 rails 層規則、React PR 讀 react 層」
# 只能在這裡逐 PR 切換，沒辦法在注入時一次做完。
#
# 對應與目錄在開跑之前一次驗完，不是跑到那個 PR 才發現：一輪回測要幾小時，
# 跑到第 20 個 PR 才報「react 層的 persona 目錄不存在」，前面的時間就白燒了。
#
# 查不到所屬層的 repo 直接擋下來，不退回 common：退回去的話，那個 repo 的 PR
# 會用一份不含自己這層規則的 prompt 跑完，summary 看起來完全正常，而「這一層
# 到底有沒有被測到」事後查不出來——正是這支腳本一路在防的「失敗長得像一個
# 合理的結果」。補一行到 lib/corpus-internal.sh 的對應表就能解決，不值得用一個
# 看不見的降級去換。
#
# 已知限制：分層的粒度是 repo，不是檔案路徑。acme/nest-monorepo-2.0 是 turbo +
# pnpm 的 monorepo，PR 常橫跨 apps/frontend 與 apps/backend（見
# docs/superpowers/notes/2026-backtest-baseline.md），但它在對應表裡只能是
# nestjs 層，所以它的前端改動拿到的是 nestjs 層的規則。要做到更細的粒度得讓
# 同一次 review 依檔案載入不同 persona，而 persona 目錄一次只能指向一個地方
# ——那是 review 流程本身的結構，不是這裡能繞過的。它在基準集裡佔 22/38 個
# PR，解讀分層回測的數字時要記得這件事。
#
# --recompute 例外：那個模式一次 review 都不跑，載入哪一份 persona 完全不影響
# 結果。注入後的 persona 放在 TMPDIR 底下，換容差重算時它可能早就被系統清掉
# 了——為一個根本不會被讀到的目錄擋下重算，是拿一道防呆去擋一件不會出錯的事。
PERSONAS_ROOT="${MRA_PERSONAS_ROOT:-}"
if [[ "$RECOMPUTE" -eq 1 ]]; then
  PERSONAS_ROOT=""
fi
if [[ -n "$PERSONAS_ROOT" ]]; then
  [[ -d "$PERSONAS_ROOT" ]] || {
    echo "PERSONAS_ROOT_MISSING：MRA_PERSONAS_ROOT=${PERSONAS_ROOT} 不是目錄" >&2
    exit 1; }
  while IFS= read -r _repo; do
    [[ -n "$_repo" ]] || continue
    if ! _layer="$(corpus_internal_layer_of "$_repo")"; then
      echo "REPO_LAYER_UNKNOWN：${_repo} 不在 lib/corpus-internal.sh 的層對應表裡，無法決定要載入哪一層的規則" >&2
      exit 1
    fi
    [[ -d "$PERSONAS_ROOT/$_layer" ]] || {
      echo "PERSONAS_LAYER_MISSING：${_repo} 屬於 ${_layer} 層，但 ${PERSONAS_ROOT}/${_layer} 不存在" >&2
      exit 1; }
    echo "分層 persona：${_repo} → ${_layer} 層"
  done < <(jq -r '[.[] | select(.confirmed == true) | .repo] | unique | .[]' "$C")
fi

OUT="$BENCH_DIR/runs/$LABEL"
if ! mkdir -p "$OUT"; then
  echo "RUNDIR_MKDIR_FAILED：無法建立 ${OUT}" >&2
  exit 1
fi

# model／provider／reasoning_effort／review_mode／max_turns／
# synth_max_turns／worktree_isolated／mra_config_path 這八個不是
# run-backtest.sh 自己知道的東西：$MRA_CMD
# (可能是 adapter、可能是別的東西、也可能就是裸的 bin/mra.sh)才是唯一
# 知道「這次實際用了什麼」的地方。上一版讓這支腳本自己用 MRA_CONFIG 沒設
# 就讀共用 $MRA_DIR/config.json 去猜，猜錯了：adapter 內部衍生的設定只存
# 在它自己的子行程裡，從來不會 export 回這裡，猜出來的值是共用
# config.json 的原始值，不是 adapter 實際拿去跑 review 的值。記錯的值比
# 沒有欄位更糟：沒有欄位時人會知道要去別處查，記了錯的值，階段四會以為
# 兩輪跑在同樣條件下，而那正是這幾個欄位存在的唯一目的。
#
# 改法：每次呼叫 $MRA_CMD 都指定 MRA_BACKTEST_COND_FILE，讓它(如果認得
# 這個 env)自己把實際用的條件寫成 JSON 回報到這個檔案；這裡只負責讀，
# 讀不到就全部填 null，絕對不 fallback 去猜共用 config.json。
# MRA_BACKTEST_CMD 指向不認得這個 env 的東西(例如測試用的 stub、或真正
# 的 bin/mra.sh 本身，沒有 adapter 那層)時讀不到是正常情況，不是錯誤。
# 同一輪 --label 底下每個 PR 用的條件本來就一樣，覆寫同一個檔即可，不用
# 累積；檔名不進版控。
COND_FILE="$OUT/run-conditions.json"

all_matches='[]'; all_comments='[]'; prs=0
# 三個「不計入本次彙總」的類別，各自獨立計數＋記清單，跟 prs(成功納入彙總
# 的筆數)並列寫進 summary.json：光印到 stderr 不夠，這個回測要回報的結論
# 本身就包含「今天的設定在幾個真實 PR 上跑不完／跑失敗」，不能只讓人在跑的
# 當下看一眼 log 就沒了，之後回頭看 summary.json 也要查得到。
incomplete_list='[]'; n_incomplete=0
failed_list='[]'; n_failed=0
file_missed=0
for ((i = 0; i < n_conf; i++)); do
  item="$(jq -c "[.[] | select(.confirmed == true)] | .[$i]" "$C")"
  repo="$(printf '%s' "$item" | jq -r '.repo')"
  pr="$(printf '%s' "$item" | jq -r '.pr')"
  expected="$(printf '%s' "$item" | jq -c '.expected_findings')"
  # 套用排除清單（見上面 EXCL_FILE 的說明）。比對鍵是 (repo, pr, path, line)，
  # 跟清單裡記的一致；比對不到的條目原樣留著。
  if [[ "$EXCLUSIONS" != "[]" ]]; then
    _before="$(printf '%s' "$expected" | jq 'length')"
    expected="$(printf '%s' "$expected" | jq -c \
      --argjson ex "$EXCLUSIONS" --arg repo "$repo" --argjson pr "$pr" '
      map(select(. as $ef
        | ($ex | any(.repo == $repo and .pr == $pr
                     and .path == $ef.path and .line == $ef.line)) | not))')" || {
      echo "EXCLUSIONS_FILTER_FAILED：${repo}#${pr} 套用排除清單失敗，這個 PR 用未過濾的 expected" >&2
      expected="$(printf '%s' "$item" | jq -c '.expected_findings')"
      _before=0
    }
    _after="$(printf '%s' "$expected" | jq 'length')"
    excluded_count=$((excluded_count + _before - _after))
  fi

  # 檔名鍵是 (repo, pr)：repo 裡的 '/' 全部換成 '__' 再接 '__<pr>.json'，跟
  # candidates.json 合併時用的鍵同一個道理——不能只用 pr，不同 repo 的 PR
  # 編號會撞。
  safe_repo="${repo//\//__}"
  f="$OUT/${safe_repo}__${pr}.json"
  # stderr 不再丟進 /dev/null，改存進同目錄的 .err 檔：實跑時 review 沒跑完
  # (codex/claude per-attempt timeout、探索預算燒光…)完全找不到原因，因為
  # 診斷訊息(含 lib/review.sh 在 MRA_REVIEW_EMIT_JSON=1 時改道 stderr 印的
  # log_progress／log_info／log_warn)全被丟掉了。這是回測用的暫存目錄，不
  # 進版控，不用擔心體積(單筆實測 1.78MB)。
  errf="$OUT/${safe_repo}__${pr}.err"

  if [[ ! -s "$f" ]] && [[ "$RECOMPUTE" -eq 1 ]]; then
    # --recompute：沒有現成結果的 PR 就是這一輪跑不出來的，記成 failed 跳過。
    # 不重跑，也就不會覆寫它的 .err —— 那份 .err 是判斷失敗原因的唯一證據。
    echo "RECOMPUTE_SKIP：${repo}#${pr} 沒有現成的 review 輸出，這個 PR 不計入本次彙總（--recompute 不跑 review）" >&2
    n_failed=$((n_failed + 1))
    failed_list="$(jq -n --argjson a "$failed_list" --arg k "${repo}#${pr}" '$a + [$k]')"
    continue
  fi
  if [[ ! -s "$f" ]]; then
    # 這個 PR 要用哪一份 persona。沒開分層時就是呼叫端原本給的值（可能是
    # 空字串，_personas_dir() 對空字串與未設定的處理相同，會用內建的
    # agents/personas）。開了分層時，上面的預檢已經確認每個 repo 都查得到
    # 層、每層的目錄都存在，這裡仍然接住退出碼：查表失敗時寧可整輪停下來，
    # 也不要讓一個空字串把這個 PR 悄悄換成沒有規則的 persona。
    persona_dir="${MRA_PERSONAS_DIR:-}"
    if [[ -n "$PERSONAS_ROOT" ]]; then
      if ! layer="$(corpus_internal_layer_of "$repo")"; then
        echo "REPO_LAYER_UNKNOWN：${repo} 查不到所屬層，停止本輪回測" >&2
        exit 1
      fi
      persona_dir="$PERSONAS_ROOT/$layer"
    fi
    if ! MRA_PERSONAS_DIR="$persona_dir" MRA_BACKTEST_COND_FILE="$COND_FILE" "$MRA_CMD" review "$repo" --pr "$pr" --strategy personas --json > "$f" 2>"$errf"; then
      echo "REVIEW_FAILED：${repo}#${pr} 的 review 失敗，詳見 ${errf}，這個 PR 不計入本次彙總" >&2
      rm -f "$f"
      n_failed=$((n_failed + 1))
      failed_list="$(jq -n --argjson a "$failed_list" --arg k "${repo}#${pr}" '$a + [$k]')"
      continue
    fi
  fi
  if ! jq -e '.comments' "$f" >/dev/null 2>&1; then
    echo "REVIEW_SHAPE_INVALID：${repo}#${pr} 的輸出 ${f} 不符合 review 輸出格式，這個 PR 不計入本次彙總" >&2
    # 併進 failed 計數，不要讓它從三個計數器裡一起消失：不計數的話
    # prs + failed + incomplete 會小於 candidates_confirmed，而 summary.json
    # 裡沒有任何欄位解釋那個缺口。覆蓋率門檻算的是 prs / n_conf，所以少算的
    # PR 仍然會壓低覆蓋率、該擋的還是會擋；問題純粹是事後看 summary 時查不到
    # 那個 PR 去哪了。這種「數字對不起來但沒有錯誤訊息」正是這支腳本一路在防
    # 的形狀。
    n_failed=$((n_failed + 1))
    failed_list="$(jq -n --argjson a "$failed_list" --arg k "${repo}#${pr}" '$a + [$k]')"
    # 跟下面 REVIEW_INCOMPLETE 同一個理由：輸出檔一定要刪。留著的話下次續跑
    # 會被上面的 -s 判定成「已經有結果」而跳過，這個 PR 就永遠不會重跑。形狀
    # 不合法最常見的來源正是回測被外力中止（額度耗盡、Ctrl-C）時 `> "$f"` 已
    # 建檔但還沒寫完，而續跑正是這種中止之後才會做的事——不刪等於把一次可以
    # 自動修復的中斷，變成一個要人工發現的永久缺口。
    #
    # --recompute 例外：那個模式不重跑任何東西，刪掉只是把證據丟了，而且會讓
    # 連跑兩次得到不同的結果（第二次變成 RECOMPUTE_SKIP），違反它自己宣告的
    # 「重算容差不該有副作用」。
    [[ "$RECOMPUTE" -eq 1 ]] || rm -f "$f"
    continue
  fi

  # status=="COMMENT" 只可能是 REVIEW_INCOMPLETE：inline schema 只允許
  # APPROVED/CHANGES_REQUESTED(見 lib/review.sh 對 single-pass inline 分支
  # 的註解)，COMMENT 是 _review_singlepass_body(lib/review-json.sh)在 raw
  # 為空或找不到完成 sentinel 時的專屬產物。形狀完全合法(comments 陣列
  # 照樣存在，可能是空的)，但內容是假的，不是「跑完了、零發現」。不擋下來
  # 的話，一次沒跑完的 review 會被當成「跑完了、零發現」，那個 PR 的
  # expected finding 全數計入漏抓，跟檔頭寫的 false-green 是同一種形狀：
  # 失敗長得像一個合理的數字。
  status="$(jq -r '.status' "$f" 2>/dev/null)"
  if [[ "$status" == "COMMENT" ]]; then
    echo "REVIEW_INCOMPLETE：${repo}#${pr} 的 review 沒有跑完(status=COMMENT)，詳見 ${errf}，這個 PR 不計入本次彙總" >&2
    # 輸出檔一定要刪：留著的話下次續跑會被上面的 -s 判定成「已經有結果」
    # 而跳過，這個 PR 就永遠不會重跑，永遠卡在跑不完的狀態。
    # --recompute 例外，理由同上面的 SHAPE_INVALID 分支。
    [[ "$RECOMPUTE" -eq 1 ]] || rm -f "$f"
    n_incomplete=$((n_incomplete + 1))
    incomplete_list="$(jq -n --argjson a "$incomplete_list" --arg k "${repo}#${pr}" '$a + [$k]')"
    continue
  fi

  review="$(cat "$f")"
  if ! m="$(backtest_match "$review" "$expected" "$TOL")"; then
    echo "MATCH_FAILED：配對 ${repo}#${pr} 的 expected 與 comment 失敗，這個 PR 不計入本次彙總" >&2
    n_failed=$((n_failed + 1))
    failed_list="$(jq -n --argjson a "$failed_list" --arg k "${repo}#${pr}" '$a + [$k]')"
    continue
  fi

  # 檔案層級的漏抓要在攤平之前算。這一步失敗時整個 PR 都不計入彙總，而
  # all_matches／all_comments 一旦 append 就收不回來——舊版把它放在 append
  # 之後，失敗時的 continue 只跳過 prs 計數，那個 PR 的 match 與 comment 已經
  # 進了彙總：expected_total 與 comments_total 含它、覆蓋率的分子不含它
  # （可能因此誤觸 COVERAGE_TOO_LOW），anchor_drift（missed 減 file_missed）
  # 的被減數含它、減數不含它，於是漂移數被墊高。summary.json 裡沒有任何欄位
  # 解釋這個缺口，正是這支腳本一路在防的「數字錯得不明顯」。
  #
  # 退出碼要接住。寫成 `$((x + $(cmd)))` 的話，cmd 失敗時它的輸出是空字串，
  # 算術展開把空字串當 0，於是 file_missed 保持不變、prs 照樣加一 —— 那個 PR
  # 的檔案層級漏抓被靜默算成 0。
  if ! _pr_file_missed="$(backtest_file_missed "$review" "$expected")"; then
    echo "FILE_MISSED_FAILED：計算 ${repo}#${pr} 的檔案層級漏抓失敗，這個 PR 不計入本次彙總" >&2
    n_failed=$((n_failed + 1))
    failed_list="$(jq -n --argjson a "$failed_list" --arg k "${repo}#${pr}" '$a + [$k]')"
    continue
  fi
  # matched_idx 是 backtest_match 相對「這個 PR 自己的 comments 陣列」算出來的
  # 位置，不是全域位置。把好幾個 PR 的 match／comment 攤平進同一個陣列之前，
  # 要先把 matched_idx 位移攤平前已經累積的 comment 筆數(offset)——不然後面
  # 進來的 PR，它的 matched_idx 會撞到攤平陣列裡屬於前面 PR 的位置，
  # backtest_metrics 判斷 unmatched 靠的正是這個位置，位移沒做對，撞到的那筆
  # comment 會被錯判成未對應，而它本來要蓋住的位置又會被錯放過。
  offset="$(jq 'length' <<<"$all_comments")"
  m="$(jq --argjson off "$offset" \
    'map(if .matched_idx == null then . else .matched_idx += $off end)' <<<"$m")"
  all_matches="$(jq -n --argjson a "$all_matches" --argjson b "$m" '$a + $b')"
  all_comments="$(jq -n --argjson a "$all_comments" --argjson r "$review" '$a + $r.comments')"
  # 檔案層級的漏抓逐 PR 累加，不能事後對攤平的陣列算一次：不同 PR 常常改到
  # 同名的檔案，攤平之後這個 PR 的 expected 會配到別的 PR 對同名檔案的
  # comment，漏抓數偏低。上面 matched_idx 靠 offset 補救，這個沒有 offset
  # 可補，只能不要攤平。實際的計算在 append 之前就做完了，見那邊的說明。
  file_missed=$((file_missed + _pr_file_missed))
  prs=$((prs + 1))
done

# 所有 confirmed 的 PR 都跑失敗時，跟「一開始就沒有 confirmed 的 PR」是同一種
# 假象：$prs 為 0，彙總出來的每個指標也會全是 0，看起來像「跑過而且零缺失」，
# 實際上什麼都沒跑成。這裡要用跟開頭同一種態度擋下來，不讓它悄悄變成一份
# 假的完美分數。
if [[ "$prs" -eq 0 ]]; then
  echo "ALL_REVIEWS_FAILED：所有 confirmed 的 PR 都跑失敗了，沒有東西可以彙總" >&2
  exit 1
fi

# 覆蓋率下限：$prs 不是 0，不代表算出來的三個指標可用。ALL_REVIEWS_FAILED
# 防的是「完全沒跑成」，沒防「跑成的太少」，那是同一種假象更隱蔽的版本。
# 實測過：38 筆裡 34 筆因為 claude OAuth session 過期跑到一半失敗，只剩不
# 具代表性的前 4 筆算出指標，其中 severity_rate 剛好是完美的 1.0，單看
# 這幾個數字會誤判成「這個模式大幅優於現況」，而不是「只跑了 4 筆」。
#
# 一份 summary 的用途是拿去跟另一份比(--compare)。分母差距太大時，兩個
# 數字之間的差異主要來自樣本、不是規則：這種情況下與其產出一份需要人自己
# 記得「那次只跑了 4 筆」才能正確解讀的檔案，不如不產出，讓失敗長成一個
# 明確的退出碼，而不是一份看起來正常的 summary.json。
#
# 門檻預設 0.8，可用 MRA_BACKTEST_MIN_COVERAGE 調整；設成 0 等同停用這道
# 檢查(成功比例永遠 >= 0，不可能小於 0)。剛好等於門檻算通過(用 < 不用
# <=)。輸入先驗證是不是合法數字，不合法時用自己的 token 擋下來，不要讓
# 使用者看到 jq 自己吐的 parse error。
coverage="$(jq -n --argjson p "$prs" --argjson n "$n_conf" '$p / $n')"
if jq -n --argjson c "$coverage" --argjson m "$MIN_COVERAGE" -e '$c < $m' >/dev/null; then
  coverage_display="$(jq -n --argjson c "$coverage" '($c * 10000 | round) / 10000')"
  echo "COVERAGE_TOO_LOW：成功納入彙總 ${prs} 筆，confirmed 共 ${n_conf} 筆，實際比例 ${coverage_display}，低於門檻 ${MIN_COVERAGE}。這一輪的數字不可用，不是 review 品質問題，請查各 PR 的 .err 檔找失敗原因" >&2
  exit 1
fi

aggregate_review="$(jq -n --argjson c "$all_comments" '{status: "COMMENT", summary: "aggregate", comments: $c}')"
summary_metrics="$(backtest_metrics "$all_matches" "$aggregate_review")" ||
  { echo "METRICS_FAILED：計算彙總指標失敗" >&2; exit 1; }

# --- 執行條件：三個指標全部由 $TOL 決定，$TOL 沒被記錄的話，兩份 summary
# 看起來可比、實際上可能是不同容差算出來的，檔案裡沒有任何線索。同理，
# review 模式、model、reasoning effort、turn 上限、有沒有 worktree 隔離、
# 基準集本身的內容，都會改變算出來的數字，也都要記，不能只記數字本身。
# 這些欄位跟三個指標一樣走同一條 tmp→mv，不另外寫檔。
#
# model／provider／reasoning_effort／review_mode／max_turns／
# synth_max_turns／worktree_isolated／mra_config_path 這八個一律從
# $COND_FILE 讀，絕對不 fallback 去讀共用的 $MRA_DIR/config.json 或用其他
# 方式猜。猜過一次，猜錯了(見這次改動的由來)。$COND_FILE 讀不到(檔案不
# 存在、是空的、或不是合法 JSON，例如 $MRA_CMD 根本不認得
# MRA_BACKTEST_COND_FILE 這個 env)是正常情況，不是錯誤：這八個欄位全部填
# null，conditions_source 記成 "unavailable"，讓看報告的人知道「這裡沒有
# 東西」，不是「這裡有一個猜測出來、可能是錯的值」。
#
# 欄位原本叫 codex_model：personas 模式跑的是 claude，填進一個叫
# codex_model 的鍵本身就是錯的值，跟上一輪剛修掉的問題同一類，改名成
# model，另外加一個 provider 欄位標明這個 model 是哪個 provider 的。
#
# agent_max_turns 欄位同一個問題再犯一次：那個值只影響 debate 路徑的
# round-1 agent，standard／personas 這兩條回測會走到的路徑都不受它控制，
# 記它等於記了一個看起來有意義、實際上不適用的值。改名 max_turns，adapter
# 那邊已經改成回報這個模式(standard 讀 MRA_REVIEW_STANDARD_MAX_TURNS、
# personas 讀 MRA_REVIEW_PERSONA_MAX_TURNS)實際生效的上限。新增
# synth_max_turns：personas 模式 synthesize 這一步的 turn 上限
# (MRA_REVIEW_SYNTH_MAX_TURNS，上一輪才讓它可調，階段四要看得出跑在什麼
# 值)，standard 模式沒有 synthesize，是 null。
if [[ -s "$COND_FILE" ]] && jq -e . "$COND_FILE" >/dev/null 2>&1; then
  conditions_source="adapter"
  conditions_json="$(jq -c '{model: (.model // null),
                              provider: (.provider // null),
                              reasoning_effort: (.reasoning_effort // null),
                              review_mode: (.review_mode // null),
                              max_turns: (.max_turns // null),
                              synth_max_turns: (.synth_max_turns // null),
                              worktree_isolated: (.worktree_isolated // null),
                              mra_config_path: (.mra_config_path // null)}' "$COND_FILE")"
else
  conditions_source="unavailable"
  conditions_json='{"model":null,"provider":null,"reasoning_effort":null,"review_mode":null,"max_turns":null,"synth_max_turns":null,"worktree_isolated":null,"mra_config_path":null}'
fi

# candidates_sha：候選集內容的指紋，不是路徑或檔名。階段四若重建過候選集
# (重跑 build-benchmark.sh 補新 PR、或人工確認的內容改了)，分母就不同，
# 但沒有這個欄位的話完全看不出來。candidates_confirmed 是它的可讀版本，
# 兩個都留：一個給人看差異方向，一個給程式精確比對是不是同一份。這兩個
# 欄位是 run-backtest.sh 自己知道的東西，不受這次改動影響，維持原樣。
candidates_sha="$(shasum -a 256 "$C" | cut -c1-16)"

# candidates_effective_sha：只涵蓋真正影響比較的部分，也就是 confirmed==true
# 的項目的 (repo, pr, expected_findings)。
#
# candidates_sha 算的是整份檔案，包含 confirmed=false 的候選與每次重跑
# build-benchmark.sh 都會變的 fix_commits。那兩樣都不參與指標計算，卻會讓
# sha 變動 —— 加一筆還沒人工確認的候選，兩輪的 sha 就對不上，看起來像基準集
# 換了，實際上分母一模一樣。方向是過度敏感，不會把不同的基準集誤判成相同
# （那才危險），但會讓相同的被誤判成不同，而那正是這個欄位要回答的問題。
#
# 兩個都留：舊欄位讓階段二已經跑完的四份 summary 仍然可以對照，新欄位給出
# 正確的語意。expected_findings 內部先排序再算，避免同一組 finding 因為
# --add 的順序不同而算出不同的指紋。
# 排序鍵對非物件的 expected finding 要有退路。candidates.json 沒有 schema，
# 手動編輯寫得出一筆字串（而不是 {path,line,severity,note} 物件），而
# `sort_by([.path, ...])` 對字串會直接報「Cannot index string with string」。
#
# 那一筆早在上面的迴圈裡就被 MATCH_FAILED 記成 failed、排除在彙總之外了；
# 讓它在這裡把整輪的結果丟掉，等於為了算一個指紋而把幾小時的 review 全部
# 作廢。全是物件時排序鍵與原本逐字元相同，所以既有的 sha 不會變動。
candidates_effective_sha="$(jq -S -c '
  [ .[] | select(.confirmed == true)
    | {repo, pr,
       expected_findings: (.expected_findings
         | sort_by(if type == "object" then [.path, .line, .severity, .note]
                   else [tojson] end)) } ]
  | sort_by([.repo, .pr])' "$C" | shasum -a 256 | cut -c1-16)" || {
  echo "SHA_FAILED：計算 candidates_effective_sha 失敗" >&2
  exit 1
}

_write_summary "$OUT/summary.json" \
  --argjson m "$summary_metrics" --argjson prs "$prs" --arg label "$LABEL" \
  --argjson incomplete_count "$n_incomplete" --argjson incomplete_prs "$incomplete_list" \
  --argjson failed_count "$n_failed" --argjson failed_prs "$failed_list" \
  --argjson tolerance "$TOL" \
  --argjson exclusions_applied "$EXCLUSIONS_APPLIED" \
  --argjson excluded_count "$excluded_count" \
  --argjson file_missed "$file_missed" \
  --argjson conditions "$conditions_json" --arg conditions_source "$conditions_source" \
  --arg candidates_sha "$candidates_sha" \
  --arg candidates_effective_sha "$candidates_effective_sha" \
  --argjson candidates_confirmed "$n_conf" \
  '$m + {prs: $prs, label: $label,
         incomplete_count: $incomplete_count, incomplete_prs: $incomplete_prs,
         failed_count: $failed_count, failed_prs: $failed_prs,
         tolerance: $tolerance,
         exclusions_applied: $exclusions_applied,
         excluded_count: $excluded_count,
         file_missed: $file_missed,
         file_miss_rate: (if $m.expected_total == 0 then 0
                          else (($file_missed / $m.expected_total) * 100 | round) / 100 end),
         anchor_drift: ($m.missed - $file_missed),
         candidates_sha: $candidates_sha,
         candidates_effective_sha: $candidates_effective_sha,
         candidates_confirmed: $candidates_confirmed}
   + $conditions + {conditions_source: $conditions_source}' || exit 1

echo "label=$LABEL prs=$prs incomplete=$n_incomplete failed=$n_failed"
# 四個數字一起印：只看漏抓率會把「沒看到那個檔案」與「看到了但錨點落在幾十行
# 外」讀成同一件事。anchor_drift 是兩者的差，也就是「行號容差算漏、但同一個
# 檔案其實有講」的條數。
jq -r '"漏抓率 \(.miss_rate)  同檔完全沒講 \(.file_miss_rate)  錨點漂移 \(.anchor_drift) 條  未對應率 \(.unmatched_rate)  嚴重度吻合率 \(.severity_rate)"' "$OUT/summary.json"
