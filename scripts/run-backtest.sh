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
    printf '%-18s %10s %10s\n' "指標" "$LABEL_A" "$LABEL_B"
    for k in expected_total missed miss_rate comments_total unmatched unmatched_rate severity_agree severity_rate; do
      VAL_A="$(printf '%s' "$JSON_A" | jq -r --arg k "$k" '.[$k]' 2>/dev/null)" ||
        { echo "READ_FAILED：解析 ${SUM_A} 失敗" >&2; exit 1; }
      VAL_B="$(printf '%s' "$JSON_B" | jq -r --arg k "$k" '.[$k]' 2>/dev/null)" ||
        { echo "READ_FAILED：解析 ${SUM_B} 失敗" >&2; exit 1; }
      printf '%-18s %10s %10s\n' "$k" "$VAL_A" "$VAL_B"
    done
    exit 0 ;;
esac

LABEL=""; TOL=5
while [[ $# -gt 0 ]]; do
  case "$1" in
    --label)
      [[ $# -ge 2 ]] || { echo "用法：--label 需要接一個值" >&2; exit 1; }
      LABEL="$2"; shift 2 ;;
    --tolerance)
      [[ $# -ge 2 ]] || { echo "用法：--tolerance 需要接一個值" >&2; exit 1; }
      TOL="$2"; shift 2 ;;
    -h|--help)
      echo "用法: run-backtest.sh --label <名稱> [--tolerance N] | --compare <a> <b>"
      exit 0 ;;
    *) echo "未知參數：$1" >&2; exit 1 ;;
  esac
done
[[ -z "$LABEL" ]] && { echo "缺 --label" >&2; exit 1; }
[[ -f "$C" ]] || { echo "找不到 ${C}" >&2; exit 1; }

n_conf="$(jq '[.[] | select(.confirmed == true)] | length' "$C")" ||
  { echo "READ_FAILED：讀取 ${C} 失敗" >&2; exit 1; }
if [[ "$n_conf" -eq 0 ]]; then
  echo "NO_CONFIRMED：基準集裡沒有 confirmed==true 的 PR，先跑 scripts/review-benchmark.sh 完成人工確認" >&2
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

OUT="$BENCH_DIR/runs/$LABEL"
if ! mkdir -p "$OUT"; then
  echo "RUNDIR_MKDIR_FAILED：無法建立 ${OUT}" >&2
  exit 1
fi

# codex_model／reasoning_effort／review_mode／agent_max_turns／
# worktree_isolated 這五個不是 run-backtest.sh 自己知道的東西：$MRA_CMD
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
for ((i = 0; i < n_conf; i++)); do
  item="$(jq -c "[.[] | select(.confirmed == true)] | .[$i]" "$C")"
  repo="$(printf '%s' "$item" | jq -r '.repo')"
  pr="$(printf '%s' "$item" | jq -r '.pr')"
  expected="$(printf '%s' "$item" | jq -c '.expected_findings')"

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

  if [[ ! -s "$f" ]]; then
    if ! MRA_BACKTEST_COND_FILE="$COND_FILE" "$MRA_CMD" review "$repo" --pr "$pr" --strategy personas --json > "$f" 2>"$errf"; then
      echo "REVIEW_FAILED：${repo}#${pr} 的 review 失敗，詳見 ${errf}，這個 PR 不計入本次彙總" >&2
      rm -f "$f"
      n_failed=$((n_failed + 1))
      failed_list="$(jq -n --argjson a "$failed_list" --arg k "${repo}#${pr}" '$a + [$k]')"
      continue
    fi
  fi
  if ! jq -e '.comments' "$f" >/dev/null 2>&1; then
    echo "REVIEW_SHAPE_INVALID：${f} 不符合 review 輸出格式，這個 PR 不計入本次彙總" >&2
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
    rm -f "$f"
    n_incomplete=$((n_incomplete + 1))
    incomplete_list="$(jq -n --argjson a "$incomplete_list" --arg k "${repo}#${pr}" '$a + [$k]')"
    continue
  fi

  review="$(cat "$f")"
  m="$(backtest_match "$review" "$expected" "$TOL")"
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
MIN_COVERAGE="${MRA_BACKTEST_MIN_COVERAGE:-0.8}"
if ! jq -n --argjson m "$MIN_COVERAGE" 'true' >/dev/null 2>&1; then
  echo "MIN_COVERAGE_INVALID：MRA_BACKTEST_MIN_COVERAGE=${MIN_COVERAGE} 不是合法數字" >&2
  exit 1
fi
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
# model／provider／reasoning_effort／review_mode／agent_max_turns／
# worktree_isolated／mra_config_path 這七個一律從 $COND_FILE 讀，絕對不
# fallback 去讀共用的 $MRA_DIR/config.json 或用其他方式猜。猜過一次，
# 猜錯了(見這次改動的由來)。$COND_FILE 讀不到(檔案不存在、是空的、或不是
# 合法 JSON，例如 $MRA_CMD 根本不認得 MRA_BACKTEST_COND_FILE 這個 env)是
# 正常情況，不是錯誤：這七個欄位全部填 null，conditions_source 記成
# "unavailable"，讓看報告的人知道「這裡沒有東西」，不是「這裡有一個猜測
# 出來、可能是錯的值」。
#
# 欄位原本叫 codex_model：personas 模式跑的是 claude，填進一個叫
# codex_model 的鍵本身就是錯的值，跟上一輪剛修掉的問題同一類，改名成
# model，另外加一個 provider 欄位標明這個 model 是哪個 provider 的。
if [[ -s "$COND_FILE" ]] && jq -e . "$COND_FILE" >/dev/null 2>&1; then
  conditions_source="adapter"
  conditions_json="$(jq -c '{model: (.model // null),
                              provider: (.provider // null),
                              reasoning_effort: (.reasoning_effort // null),
                              review_mode: (.review_mode // null),
                              agent_max_turns: (.agent_max_turns // null),
                              worktree_isolated: (.worktree_isolated // null),
                              mra_config_path: (.mra_config_path // null)}' "$COND_FILE")"
else
  conditions_source="unavailable"
  conditions_json='{"model":null,"provider":null,"reasoning_effort":null,"review_mode":null,"agent_max_turns":null,"worktree_isolated":null,"mra_config_path":null}'
fi

# candidates_sha：候選集內容的指紋，不是路徑或檔名。階段四若重建過候選集
# (重跑 build-benchmark.sh 補新 PR、或人工確認的內容改了)，分母就不同，
# 但沒有這個欄位的話完全看不出來。candidates_confirmed 是它的可讀版本，
# 兩個都留：一個給人看差異方向，一個給程式精確比對是不是同一份。這兩個
# 欄位是 run-backtest.sh 自己知道的東西，不受這次改動影響，維持原樣。
candidates_sha="$(shasum -a 256 "$C" | cut -c1-16)"

_write_summary "$OUT/summary.json" \
  --argjson m "$summary_metrics" --argjson prs "$prs" --arg label "$LABEL" \
  --argjson incomplete_count "$n_incomplete" --argjson incomplete_prs "$incomplete_list" \
  --argjson failed_count "$n_failed" --argjson failed_prs "$failed_list" \
  --argjson tolerance "$TOL" \
  --argjson conditions "$conditions_json" --arg conditions_source "$conditions_source" \
  --arg candidates_sha "$candidates_sha" --argjson candidates_confirmed "$n_conf" \
  '$m + {prs: $prs, label: $label,
         incomplete_count: $incomplete_count, incomplete_prs: $incomplete_prs,
         failed_count: $failed_count, failed_prs: $failed_prs,
         tolerance: $tolerance,
         candidates_sha: $candidates_sha, candidates_confirmed: $candidates_confirmed}
   + $conditions + {conditions_source: $conditions_source}' || exit 1

echo "label=$LABEL prs=$prs incomplete=$n_incomplete failed=$n_failed"
jq -r '"漏抓率 \(.miss_rate)  未對應率 \(.unmatched_rate)  嚴重度吻合率 \(.severity_rate)"' "$OUT/summary.json"
