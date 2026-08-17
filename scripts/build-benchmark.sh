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
n_candidates=0
# 兩個計數器分開算，不是同一個 n_failed：外層（每個 PR 一次）跟內層（每個
# fix commit 一次）失敗的成因通常不同（org 層級 API 中斷 vs 單一 commit
# 查不到），混在同一個數字裡，操作者事後看報告分不出是哪一種，等於白算。
n_failed_pr=0
n_failed_commit=0
for ((i = 0; i < n_pr; i++)); do
  pr="$(printf '%s' "$prs" | jq -r ".[$i].n")"
  merged="$(printf '%s' "$prs" | jq -r ".[$i].merged_at")"
  own="$(printf '%s' "$prs" | jq -r ".[$i].merge_commit_sha")"

  # 這兩個 lookup 的失敗跟「這個 PR 沒有候選」是兩種不同的事，不能用同一個
  # continue 混在一起：gh 對某個 org 的 /commits 端點局部中斷時，
  # backtest_fix_commits／backtest_pr_ranges 會回非 0（見函式庫檔頭），
  # 這是 API 壞了，不是「查過、確定沒有 fix commit／沒有 PR 區間」。混在一起
  # 的後果是整個 repo 因為 API 中斷什麼候選都找不到，卻印出跟「這個 repo
  # 本來就沒有候選」一模一樣的乾淨結尾（候選 0 筆、結束碼 0）——回測基準集
  # 因此悄悄少掉一整個 repo，而且完全沒有痕跡。
  if ! fixes="$(backtest_fix_commits "$REPO" "$pr" "$merged" "$own" "$DAYS")"; then
    n_failed_pr=$((n_failed_pr + 1))
    continue
  fi
  [[ "$(printf '%s' "$fixes" | jq 'length' 2>/dev/null)" -eq 0 ]] 2>/dev/null && continue

  if ! pr_ranges="$(backtest_pr_ranges "$REPO" "$pr")"; then
    n_failed_pr=$((n_failed_pr + 1))
    continue
  fi
  # PR 的 hunk 全是純刪除時區間集為空——這是誠實的結果（見
  # lib/backtest-hunks.sh 檔頭註解），不用回頭比對檔名硬湊候選，這種情況
  # 不算失敗。
  [[ "$pr_ranges" == "{}" ]] && continue

  hits='[]'
  n_fix="$(printf '%s' "$fixes" | jq 'length')"
  for ((j = 0; j < n_fix; j++)); do
    sha="$(printf '%s' "$fixes" | jq -r ".[$j].sha")"
    msg="$(printf '%s' "$fixes" | jq -r ".[$j].message")"
    # 跟外層兩個 lookup 同一個道理，而且後果更隱蔽：這裡失敗時原本的
    # || continue 只是把這個 fix commit 當成「沒有重疊」，PR 有沒有候選
    # 的判斷照樣往下走，不會有任何非 0 結束碼、也不會有任何訊息——一個
    # 真正有缺陷的候選，因為 API 中斷查不到這一個 commit 的區間，就這樣
    # 從基準集裡悄悄消失，比外層「整個 repo 交白卷」還難發現，因為外層
    # 至少會讓人注意到「這個 repo 怎麼 0 候選」。
    if ! fix_ranges="$(backtest_commit_ranges "$REPO" "$sha")"; then
      n_failed_commit=$((n_failed_commit + 1))
      continue
    fi
    ov="$(backtest_overlap "$pr_ranges" "$fix_ranges")"
    # 沒有重疊的 fix commit 不能算候選，寧可漏收也不能無中生有一筆假重疊。
    [[ "$(printf '%s' "$ov" | jq 'length')" -eq 0 ]] && continue
    hits="$(printf '%s' "$hits" | jq --arg s "$sha" --arg m "$msg" --argjson o "$ov" \
      '. + [{sha: $s, message: $m, overlaps: $o}]')"
  done

  [[ "$(printf '%s' "$hits" | jq 'length')" -eq 0 ]] && continue
  n_candidates=$((n_candidates + 1))
  result="$(printf '%s' "$result" | jq \
    --arg repo "$REPO" --argjson pr "$pr" --arg merged "$merged" --argjson h "$hits" \
    '. + [{repo: $repo, pr: $pr, merged_at: $merged, fix_commits: $h,
           confirmed: null, expected_findings: []}]')"
done

# 不管是外層還是內層失敗，這整趟掃描就不算完整：不能寫出一份看起來
# 像「掃過這個 repo、結果就是這樣」的 candidates.json——不管是全新檔案還是
# 疊在舊檔上面，都會讓沒查到的 PR／fix commit 永遠消失在紀錄裡，之後也不會
# 有人知道要重跑。直接結束，完全不碰 $OUT，舊檔（不管是不是這個 repo、也
# 不管 confirmed 填了什麼）原封不動留著。
#
# LOOKUP_FAILED 這行把外層跟內層的筆數分開印，不合成一個數字：外層失敗多半
# 是整個 org／repo 層級的 API 問題，內層失敗多半是單一 commit 查不到，兩種
# 成因不同，操作者要能從這行報告分辨是哪一種，才知道該往哪裡查。
if ((n_failed_pr > 0 || n_failed_commit > 0)); then
  printf 'LOOKUP_FAILED\t%s\t%d\t%d\t%d\n' "$REPO" "$n_failed_pr" "$n_failed_commit" "$n_pr" >&2
  exit 1
fi

# 合併：鍵是 (repo, pr) 的聯集，不是這次跑出來的 $result 的鍵集合。
#
# 這支腳本一次只認一個 --repo，但 candidates.json 是所有 repo 共用的同一個
# 檔案。早期版本用 $result（這次的結果）當合併的基底、把舊檔的值疊上去——
# 這代表舊檔裡「這次沒跑到」的每一列都會消失：同一個 PR 這次沒有重現
# （14 天視窗會漂移，舊候選本來就會定期不再命中）、或單純是別的 repo 的列
# （幫 acme/rails-app-1 重建一次，會把 acme/nest-monorepo-2.0 的每一列全部刪掉）。
# 兩種情況都會無聲弄丟已經花掉 API 成本才找到的候選，以及已經花掉人工審查
# 成本才填的 confirmed／expected_findings——這正是這支腳本存在的理由要防
# 的那種遺失。
#
# 正確作法：以聯集為準。
#   只在舊檔出現 → 原封不動地留著（即使 confirmed 還是 null，那也是已經
#     花過 API 成本才找到的候選，不能因為這次沒重新命中就當作沒發生過）。
#   只在這次結果出現 → 用這次的值，confirmed/expected_findings 是新的
#     null/[]。
#   兩邊都有 → 機器算出來的欄位用這次的新值蓋過去，但 confirmed 與
#     expected_findings 原封不動地從舊檔留下來。
# 鍵一定要用 (repo, pr) 兩個欄位一起組，不能只用 pr：不同 repo 的 PR 編號
# 會撞。
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
  | (.[1] | map({key: (.repo + "#" + (.pr | tostring)), value: .}) | from_entries) as $new
  | (($old | keys) + ($new | keys) | unique) as $keys
  | [ $keys[] as $k
      | if ($new[$k] != null) then
          if ($old[$k] != null) then
            ($new[$k] | .confirmed = $old[$k].confirmed
                       | .expected_findings = $old[$k].expected_findings)
          else
            $new[$k]
          end
        else
          $old[$k]
        end
    ]
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

# 掃了幾筆 PR、這次找到幾筆候選、失敗幾筆（PR／commit 分開列，這裡一定都是
# 0，非 0 在上面已經 exit 1）都要印出來——不然掃 3 筆跟掃 100 筆會印出同一種
# 「乾淨結尾」，沒有東西能分辨這次到底掃了多少。
echo "掃描 $n_pr 筆 merged PR，本次候選 $n_candidates 筆，失敗 0 筆（PR lookup 0／commit lookup 0）→ $REPO"
echo "候選（累計，所有 repo）$(jq 'length' "$OUT") 筆 → $OUT"
echo "未確認 $(jq '[.[] | select(.confirmed == null)] | length' "$OUT") 筆，執行 Task 4 的人工確認"
