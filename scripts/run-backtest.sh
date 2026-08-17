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

all_matches='[]'; all_comments='[]'; prs=0
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

  if [[ ! -s "$f" ]]; then
    if ! "$MRA_CMD" review "$repo" --pr "$pr" --strategy personas --json > "$f" 2>/dev/null; then
      echo "REVIEW_FAILED：${repo}#${pr} 的 review 失敗，這個 PR 不計入本次彙總" >&2
      rm -f "$f"
      continue
    fi
  fi
  if ! jq -e '.comments' "$f" >/dev/null 2>&1; then
    echo "REVIEW_SHAPE_INVALID：${f} 不符合 review 輸出格式，這個 PR 不計入本次彙總" >&2
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

aggregate_review="$(jq -n --argjson c "$all_comments" '{status: "COMMENT", summary: "aggregate", comments: $c}')"
summary_metrics="$(backtest_metrics "$all_matches" "$aggregate_review")" ||
  { echo "METRICS_FAILED：計算彙總指標失敗" >&2; exit 1; }

_write_summary "$OUT/summary.json" \
  --argjson m "$summary_metrics" --argjson prs "$prs" --arg label "$LABEL" \
  '$m + {prs: $prs, label: $label}' || exit 1

echo "label=$LABEL prs=$prs"
jq -r '"漏抓率 \(.miss_rate)  未對應率 \(.unmatched_rate)  嚴重度吻合率 \(.severity_rate)"' "$OUT/summary.json"
