#!/usr/bin/env bash
# 建構回測基準集的候選清單。
#
# 只產出候選。人工確認在 Task 4，重跑時已填的 confirmed 與 expected_findings
# 會保留，不會被覆蓋——這是整段 stage 最貴的一步，弄丟就要重做人工確認。
set -uo pipefail

MRA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$MRA_DIR/lib/backtest-hunks.sh"
source "$MRA_DIR/lib/backtest-groundtruth.sh"
source "$MRA_DIR/lib/backtest-blame.sh"

REPO=""; LIMIT=100; DAYS=14; UNTIL=""
# 候選的判定方式：
#   overlap（預設）fix commit 的行號區間跟 PR 的行號區間有交集。全走 gh API。
#   blame          fix commit 改到的舊行 blame 回去指到 PR 的 commit（見
#                  lib/backtest-blame.sh）。PR 與 fix commit 的列表照舊走 gh，
#                  hunk 與 blame 走本機 clone：MRA_BACKTEST_WORKSPACE/<repo
#                  第二段>，跟 backtest-review-adapter.sh 用同一個慣例。
# 兩種模式產出的候選都寫進同一份 candidates.json，合併規則相同；blame 模式
# 的候選多一個 attribution: "blame" 欄位，fix_commits[] 帶 hunks 而不是
# overlaps。一個 fix commit 要有任何一個 hunk 的歸因比例達門檻才算候選，
# 門檻 MRA_BACKTEST_BLAME_MIN_RATIO，預設 0.5（54 條人工定案上的最佳值）。
ATTRIBUTION="overlap"
# 每個帶值的旗標都要先確認後面真的還有一個參數。少了這道，`--repo` 打在最後
# 一個位置時 set -u 會讓腳本死在「$2: 未綁定的變數」，訊息指向行號而不是使用者
# 打錯的那個旗標。這個專案的其他腳本（run-backtest.sh、review-benchmark.sh、
# rule-repair.sh、兩支 extract-rules）都已經補過同一道，只有這裡漏了。
_require_opt_value() {
  echo "用法：$1 需要接一個值" >&2
  exit 1
}
while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo)  [[ $# -ge 2 ]] || _require_opt_value "--repo"
             REPO="$2"; shift 2 ;;
    --limit) [[ $# -ge 2 ]] || _require_opt_value "--limit"
             LIMIT="$2"; shift 2 ;;
    --days)  [[ $# -ge 2 ]] || _require_opt_value "--days"
             DAYS="$2"; shift 2 ;;
    # 可選，見 lib/backtest-groundtruth.sh 的 backtest_merged_prs 對這個
    # 參數的說明（Ruling 27）：凍住「當時看到的世界線」，讓同一個
    # --limit／--until 組合在任何時間點重跑都抓到同一批 PR。沒給的話
    # （預設）行為與現在完全一致。
    --until) [[ $# -ge 2 ]] || _require_opt_value "--until"
             UNTIL="$2"; shift 2 ;;
    --attribution) [[ $# -ge 2 ]] || _require_opt_value "--attribution"
             ATTRIBUTION="$2"; shift 2 ;;
    -h|--help)
      echo "用法: build-benchmark.sh --repo <owner/name> [--limit N] [--days N] [--until <ISO8601>] [--attribution overlap|blame]"
      exit 0 ;;
    *) echo "未知參數：$1" >&2; exit 1 ;;
  esac
done
[[ -z "$REPO" ]] && { echo "缺 --repo" >&2; exit 1; }
case "$ATTRIBUTION" in
  overlap|blame) ;;
  *) echo "ATTRIBUTION_INVALID：--attribution 只接受 overlap 或 blame，給了「${ATTRIBUTION}」" >&2; exit 1 ;;
esac
BLAME_MIN_RATIO="${MRA_BACKTEST_BLAME_MIN_RATIO:-0.5}"
case "$BLAME_MIN_RATIO" in
  ''|*[!0-9.]*|.|*.*.*) echo "BLAME_MIN_RATIO_INVALID：MRA_BACKTEST_BLAME_MIN_RATIO 的值「${BLAME_MIN_RATIO}」不是數字" >&2; exit 1 ;;
esac
# blame 模式全靠本機 clone。clone 不在就什麼都算不出來，在還沒打任何 API
# 之前先擋，訊息指向要 clone 到哪裡。
REPO_DIR=""
if [[ "$ATTRIBUTION" == "blame" ]]; then
  REPO_DIR="${MRA_BACKTEST_WORKSPACE:-$HOME/workspace}/${REPO#*/}"
  if ! git -C "$REPO_DIR" rev-parse --git-dir >/dev/null 2>&1; then
    echo "LOCAL_REPO_MISSING：--attribution blame 需要本機 clone，找不到 ${REPO_DIR}（MRA_BACKTEST_WORKSPACE 可改路徑）" >&2
    exit 1
  fi
fi
# --limit 會變成 GitHub 的 per_page，上限是 100。超過的話 API 靜默回 100 筆，
# 分母比要求的少而且沒有任何訊號（見 lib/backtest-groundtruth.sh 的
# backtest_merged_prs）。那邊也有同一道守衛，這裡先擋是為了讓訊息指向使用者
# 打錯的旗標本身。
case "$LIMIT" in
  ''|*[!0-9]*|0) echo "LIMIT_INVALID：--limit 的值「${LIMIT}」不是正整數" >&2; exit 1 ;;
esac
if [[ "$LIMIT" -gt 100 ]]; then
  echo "LIMIT_TOO_LARGE：--limit 的上限是 100（GitHub per_page 的上限），給了 ${LIMIT}" >&2
  exit 1
fi
# --days 一路傳到 backtest_window_end 的 python3 datetime.timedelta(days=int(...))，
# 非數字會讓它以一段 Python traceback 收場，而不是一句講得清楚的用法錯誤。
case "$DAYS" in
  ''|*[!0-9]*) echo "DAYS_INVALID：--days 的值「${DAYS}」不是非負整數" >&2; exit 1 ;;
esac

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

# PR 列表本身讀不到跟「這個 repo 真的沒有任何已合併 PR」是兩回事，不能用
# 同一句話、同一個結束方式收尾：這一版事故的起點就是 /pulls 正常、/commits
# 中斷，但反過來（/pulls 中斷、/commits 正常）後果更重——外層／內層兩個
# 計數器都還沒開始跑，這裡一失敗，整個 repo 連候選名單都生不出來，卻只會
# 印出「沒有 merged PR」，跟一個真的沒有任何已合併 PR 的 repo 長得一模一樣。
# backtest_merged_prs 內部是 gh api ... | jq '[...]'，gh 失敗時 jq 多半也
# 跟著失敗、$prs 會是空字串（不是合法的 "[]"）；用 -z 這個額外檢查兜底，
# 避免萬一 jq 成功但輸出詭異地是空字串，也一併當失敗處理，不要冒然當成
# 合法的空 repo。
if ! prs="$(backtest_merged_prs "$REPO" "$LIMIT" "$UNTIL")" || [[ -z "$prs" ]]; then
  # 這裡沒有 n_failed_pr／n_failed_commit 可以印——迴圈根本還沒開始，兩個
  # 計數器都是初始值，印出來只會誤導成「查了 0 筆都沒失敗」。故意用
  # "listing" 這個字取代數字欄位，讓這行的形狀跟下面 PR／commit 層級的
  # LOOKUP_FAILED（第三欄一定是數字）一眼就分得出來：這一行代表 repo 列表
  # 本身讀不到，是完全不同的診斷，要往 /pulls 端點查，不是往個別 PR／
  # commit 查。
  printf 'LOOKUP_FAILED\t%s\tlisting\n' "$REPO" >&2
  exit 1
fi
if [[ "$prs" == "[]" ]]; then
  # 合法的空 repo：查得到 PR 列表、列表本身就是空的。這是正常結果，要
  # exit 0，不能跟上面「列表讀不到」共用同一種結束方式，否則兩種情況又會
  # 變回分不清楚。
  echo "沒有 merged PR（合法的空 repo）：$REPO"
  exit 0
fi

result='[]'
n_pr="$(printf '%s' "$prs" | jq 'length')"
n_candidates=0
# 兩個計數器分開算，不是同一個 n_failed：外層（每個 PR 一次）跟內層（每個
# fix commit 一次）失敗的成因通常不同（org 層級 API 中斷 vs 單一 commit
# 查不到），混在同一個數字裡，操作者事後看報告分不出是哪一種，等於白算。
n_failed_pr=0
n_failed_commit=0

# blame 模式：對 PR 的每個 fix commit 改到的每個檔案做歸因，結果放進全域
# $hits（跟交集模式同一個變數，後面組候選的程式碼兩種模式共用）。失敗的
# 分類跟交集模式對齊：merge commit 不在本機是 PR 層失敗（回非 0，呼叫端
# 計數）；fix commit 不在本機是 commit 層失敗（這裡直接加 n_failed_commit）。
# 兩種都印 LOCAL_COMMIT_MISSING 指出哪個 sha，操作者知道要 git fetch 什麼。
#
# 不能因為「查不到」就當成「沒有 hunk」跳過：那正是交集模式那邊花了四次
# 代價才堵住的洞（候選悄悄消失、結束碼還是 0）。
_blame_hits_for_pr() {
  local pr="$1" merged="$2" own="$3" fixes="$4"
  local n_fix j sha msg fix_date gap files path h hunks failed
  hits='[]'
  if ! git -C "$REPO_DIR" cat-file -e "${own}^{commit}" 2>/dev/null; then
    printf 'LOCAL_COMMIT_MISSING\t%s\t%s\t%s\tmerge commit 不在本機 clone %s，先 git fetch\n' \
      "$REPO" "$pr" "$own" "$REPO_DIR" >&2
    return 1
  fi
  n_fix="$(printf '%s' "$fixes" | jq 'length')"
  for ((j = 0; j < n_fix; j++)); do
    sha="$(printf '%s' "$fixes" | jq -r ".[$j].sha")"
    msg="$(printf '%s' "$fixes" | jq -r ".[$j].message")"
    if ! files="$(git -C "$REPO_DIR" diff --name-only --no-renames "${sha}^1" "$sha" 2>/dev/null)"; then
      printf 'LOCAL_COMMIT_MISSING\t%s\t%s\t%s\tfix commit 不在本機 clone %s，先 git fetch\n' \
        "$REPO" "$pr" "$sha" "$REPO_DIR" >&2
      n_failed_commit=$((n_failed_commit + 1))
      continue
    fi
    if ! fix_date="$(git -C "$REPO_DIR" show -s --format=%cI "$sha" 2>/dev/null)" \
       || ! gap="$(backtest_gap_days "$merged" "$fix_date")"; then
      n_failed_commit=$((n_failed_commit + 1))
      continue
    fi
    hunks='[]'; failed=0
    while IFS= read -r path; do
      [[ -n "$path" ]] || continue
      if ! h="$(backtest_blame_hunks "$REPO_DIR" "$own" "$sha" "$path")"; then
        failed=1; break
      fi
      # 只留有任何一行指到 PR 的 hunk；完全沒指到的 hunk 是雜訊，留著只會
      # 讓 --next 印一堆跟 PR 無關的區間
      hunks="$(printf '%s' "$hunks" | jq -c --argjson h "$h" '. + ($h | map(select(.to_pr > 0)))')"
    done <<< "$files"
    if ((failed)); then
      n_failed_commit=$((n_failed_commit + 1))
      continue
    fi
    if [[ "$(printf '%s' "$hunks" | jq --argjson m "$BLAME_MIN_RATIO" 'any(.[]; .ratio >= $m)')" != "true" ]]; then
      continue
    fi
    hits="$(printf '%s' "$hits" | jq --arg s "$sha" --arg m "$msg" --argjson g "$gap" --argjson h "$hunks" \
      '. + [{sha: $s, message: $m, gap_days: ($g + 0), hunks: $h}]')"
  done
  return 0
}
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
  # 同上：長度算不出來時不能當成「沒有 fix commit」，而且 jq 自己的診斷不能
  # 丟進 /dev/null —— 這個專案已經為丟掉診斷這個模式付過四次代價。
  if ! n_fix_found="$(printf '%s' "$fixes" | jq 'length')"; then
    n_failed_pr=$((n_failed_pr + 1))
    continue
  fi
  [[ "$n_fix_found" -eq 0 ]] && continue

  if [[ "$ATTRIBUTION" == "blame" ]]; then
    if ! _blame_hits_for_pr "$pr" "$merged" "$own" "$fixes"; then
      n_failed_pr=$((n_failed_pr + 1))
      continue
    fi
    [[ "$(printf '%s' "$hits" | jq 'length')" -eq 0 ]] && continue
    n_candidates=$((n_candidates + 1))
    result="$(printf '%s' "$result" | jq \
      --arg repo "$REPO" --argjson pr "$pr" --arg merged "$merged" --argjson h "$hits" \
      '. + [{repo: $repo, pr: $pr, merged_at: $merged, attribution: "blame", fix_commits: $h,
             confirmed: null, expected_findings: []}]')"
    continue
  fi

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
    # backtest_overlap 的退出碼跟它上面三個 lookup 一樣要接住。丟掉的話，
    # jq 失敗時 $ov 是空字串，`jq 'length'` 什麼都不印，而 bash 的算術比較
    # 把空字串當 0 —— 一筆真正的候選會被當成「沒有重疊」悄悄消失，沒有任何
    # 計數器增加，結束碼還是 0。
    if ! ov="$(backtest_overlap "$pr_ranges" "$fix_ranges")"; then
      n_failed_commit=$((n_failed_commit + 1))
      continue
    fi
    if ! ov_len="$(printf '%s' "$ov" | jq 'length')"; then
      n_failed_commit=$((n_failed_commit + 1))
      continue
    fi
    # 沒有重疊的 fix commit 不能算候選，寧可漏收也不能無中生有一筆假重疊。
    [[ "$ov_len" -eq 0 ]] && continue
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
