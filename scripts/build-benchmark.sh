#!/usr/bin/env bash
# 建構回測基準集的候選清單。
#
# 只產出候選。人工確認在 Task 4，重跑時已填的 confirmed 與 expected_findings
# 會保留，不會被覆蓋——這是整段 stage 最貴的一步，弄丟就要重做人工確認。
set -uo pipefail

MRA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$MRA_DIR/lib/backtest-hunks.sh"
source "$MRA_DIR/lib/backtest-groundtruth.sh"

REPO=""; LIMIT=100; DAYS=14
while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo)  REPO="$2"; shift 2 ;;
    --limit) LIMIT="$2"; shift 2 ;;
    --days)  DAYS="$2"; shift 2 ;;
    -h|--help)
      echo "用法: build-benchmark.sh --repo <owner/name> [--limit N] [--days N]"
      exit 0 ;;
    *) echo "未知參數：$1" >&2; exit 1 ;;
  esac
done
[[ -z "$REPO" ]] && { echo "缺 --repo" >&2; exit 1; }

BENCH_DIR="${MRA_BENCHMARK_DIR:-$HOME/.cache/mra-review-benchmark}"
if ! mkdir -p "$BENCH_DIR"; then
  echo "BENCH_DIR_MKDIR_FAILED：無法建立 $BENCH_DIR" >&2
  exit 1
fi
OUT="$BENCH_DIR/candidates.json"
if [[ ! -f "$OUT" ]]; then
  if ! printf '[]' > "$OUT"; then
    echo "INIT_WRITE_FAILED：無法建立 $OUT" >&2
    exit 1
  fi
fi

prs="$(backtest_merged_prs "$REPO" "$LIMIT")"
[[ -z "$prs" || "$prs" == "[]" ]] && { echo "沒有 merged PR：$REPO" >&2; exit 1; }

result='[]'
n_pr="$(printf '%s' "$prs" | jq 'length')"
for ((i = 0; i < n_pr; i++)); do
  pr="$(printf '%s' "$prs" | jq -r ".[$i].n")"
  merged="$(printf '%s' "$prs" | jq -r ".[$i].merged_at")"
  own="$(printf '%s' "$prs" | jq -r ".[$i].merge_commit_sha")"

  fixes="$(backtest_fix_commits "$REPO" "$pr" "$merged" "$own" "$DAYS")" || continue
  [[ "$(printf '%s' "$fixes" | jq 'length' 2>/dev/null)" -eq 0 ]] 2>/dev/null && continue

  pr_ranges="$(backtest_pr_ranges "$REPO" "$pr")" || continue
  # PR 的 hunk 全是純刪除時區間集為空——這是誠實的結果（見
  # lib/backtest-hunks.sh 檔頭註解），不用回頭比對檔名硬湊候選。
  [[ "$pr_ranges" == "{}" ]] && continue

  hits='[]'
  n_fix="$(printf '%s' "$fixes" | jq 'length')"
  for ((j = 0; j < n_fix; j++)); do
    sha="$(printf '%s' "$fixes" | jq -r ".[$j].sha")"
    msg="$(printf '%s' "$fixes" | jq -r ".[$j].message")"
    fix_ranges="$(backtest_commit_ranges "$REPO" "$sha")" || continue
    ov="$(backtest_overlap "$pr_ranges" "$fix_ranges")"
    # 沒有重疊的 fix commit 不能算候選，寧可漏收也不能無中生有一筆假重疊。
    [[ "$(printf '%s' "$ov" | jq 'length')" -eq 0 ]] && continue
    hits="$(printf '%s' "$hits" | jq --arg s "$sha" --arg m "$msg" --argjson o "$ov" \
      '. + [{sha: $s, message: $m, overlaps: $o}]')"
  done

  [[ "$(printf '%s' "$hits" | jq 'length')" -eq 0 ]] && continue
  result="$(printf '%s' "$result" | jq \
    --arg repo "$REPO" --argjson pr "$pr" --arg merged "$merged" --argjson h "$hits" \
    '. + [{repo: $repo, pr: $pr, merged_at: $merged, fix_commits: $h,
           confirmed: null, expected_findings: []}]')"
done

# 合併：已存在的 (repo, pr) 保留舊的 confirmed 與 expected_findings，其餘欄位
# 用這次重新算出來的值蓋過去。
#
# 寫檔一定先落到同目錄下的 .tmp、驗過 jq 退出碼才 mv 進正式檔名，mv 也要驗
# 退出碼：候選集不進 git，沒有第二份副本，寫壞了就是永久遺失人工確認。
# 合併用的 jq 若失敗，代表 $OUT 本身已經不是合法 JSON（唯一還算合理的成因，
# 因為 $result 全程由這支腳本自己組出來），這種情況下 $OUT 已經不可能救出
# 任何有效的 confirmed／expected_findings，留著只會讓下一輪繼續讀到同一份
# 壞掉的檔案、永遠卡住，所以連舊檔一起清掉，讓下一輪從乾淨狀態重建。
# mv 失敗（多半是磁碟滿、權限、跨檔案系統）則不動 $OUT：mv 沒開始搬就是沒
# 搬，$OUT 仍是上一輪成功寫入、完整可信的內容，這時清掉它只會平白丟掉人工
# 確認，沒有任何好處，只清掉沒搬成功的 .tmp。
OUT_TMP="$OUT.tmp"
if ! jq -s '
  (.[0] | map({key: (.repo + "#" + (.pr | tostring)), value: .}) | from_entries) as $old
  | .[1] | map(
      ($old[.repo + "#" + (.pr | tostring)]) as $prev
      | if $prev then .confirmed = $prev.confirmed
                      | .expected_findings = $prev.expected_findings
        else . end)
' "$OUT" <(printf '%s' "$result") > "$OUT_TMP"; then
  echo "MERGE_FAILED：候選合併失敗，$OUT 已損毀，清掉重來" >&2
  rm -f "$OUT_TMP" "$OUT"
  exit 1
fi

if ! mv "$OUT_TMP" "$OUT"; then
  echo "PROMOTE_FAILED：無法把候選結果寫入 $OUT" >&2
  rm -f "$OUT_TMP"
  exit 1
fi

echo "候選 $(jq 'length' "$OUT") 筆 → $OUT"
echo "未確認 $(jq '[.[] | select(.confirmed == null)] | length' "$OUT") 筆，執行 Task 4 的人工確認"
