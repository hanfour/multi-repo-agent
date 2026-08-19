#!/usr/bin/env bash
# scripts/run-backtest.sh 呼叫的是「假想中」的 mra CLI 形狀：
#
#   mra review <owner/repo> --pr <N> --strategy personas --json
#
# 真正的 mra review 不是這樣：沒有 --json；--strategy 只收 light/standard/
# debate；<project> 要是 workspace 內的專案名(erp)不是 owner/repo(acme/rails-app-1)；
# --pr N 會檢查本地 HEAD 等於 PR head，歷史上已經 merged 的 PR 一定擋下來。
#
# 這支腳本接住 run-backtest.sh 呼叫的那個假想形狀，轉譯成真正 mra review 吃得下
# 的呼叫：查出 PR 的 base/head SHA，確保兩個 commit 本地都在，改用
# --range base...head(不是 --pr)，用 MRA_REVIEW_EMIT_JSON=1 拿到跟
# backtest_match 期待形狀一致的原始 JSON。
#
# --range 用三點(base...head)，不是兩點(base..head)：兩點是「base 到 head
# 的直接差異」，會把 base 分支在分歧之後自己的變更也算進來；GitHub 網頁上
# PR 顯示的範圍、以及這個回測要量的範圍，是三點對稱差集(只有這個 PR 自己的
# commit)。實測 acme/nest-monorepo-2.0#761：兩點算出 11 個檔案、三點算出 5 個，
# GitHub 網頁顯示 5 個。兩點多出來的 6 個檔案是 base 分支的變更，reviewer 會
# 對這個 PR 根本沒改過的程式碼產生 finding，同時墊高 comment 數與
# unmatched 率，讓回測的分母本身就是錯的。
#
# 支援兩種 review 設定，透過 MRA_BACKTEST_REVIEW_MODE 選擇(見下方 case)：
# personas(預設，走 lib/review.sh 的 persona 路徑)跟 standard(--strategy
# standard --provider codex，對應團隊實際在用的設定，見 ~/.pmk/gateway.json)。
#
# 不加 --no-debate：personas 模式下回測要量的是預設的完整流程(含 debate)，
# 不是精簡過的版本。
#
# 錯誤分類每一種都給自己的 token，尤其是「API 呼叫本身失敗」跟「查得到、但
# 內容缺東西」不能混報。本專案已經因為這種混報付過四次代價(build-benchmark.sh
# 檔頭記錄的 LOOKUP_FAILED 事故就是同一個教訓)：混報的話，一次 gh 網路中斷跟
# 一個 PR 真的沒有 base/head(理論上不會發生，但別假設)看起來會一模一樣，
# 回測會把「查不到」誤判成「查到了但沒東西」，兩種情況要往完全不同的地方查。
set -uo pipefail

MRA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [[ "${1:-}" != "review" ]]; then
  echo "用法：backtest-review-adapter.sh review <owner/repo> --pr <N> [--strategy <忽略>] [--json(忽略)]" >&2
  exit 1
fi
shift

repo=""
pr=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --pr)
      [[ $# -ge 2 ]] || { echo "用法：--pr 需要接一個值" >&2; exit 1; }
      pr="$2"; shift 2 ;;
    --strategy)
      # run-backtest.sh 目前照著假想的 mra CLI 形狀傳這個旗標，真正的
      # mra review 用不到(--range 已經指定要 review 的範圍，走哪種策略由
      # MRA_BACKTEST_REVIEW_MODE 決定)，這裡吃掉、不轉傳，不當錯誤。
      [[ $# -ge 2 ]] || { echo "用法：--strategy 需要接一個值" >&2; exit 1; }
      shift 2 ;;
    --json)
      # 同上，吃掉不轉傳；MRA_REVIEW_EMIT_JSON=1 才是真正讓 mra review 吐
      # JSON 的機制。
      shift ;;
    -*)
      echo "用法：不認得的旗標 $1" >&2; exit 1 ;;
    *)
      if [[ -z "$repo" ]]; then
        repo="$1"; shift
      else
        echo "用法：多餘的位置參數 $1" >&2; exit 1
      fi
      ;;
  esac
done
[[ -n "$repo" ]] || { echo "用法：缺少 <owner/repo>" >&2; exit 1; }
[[ -n "$pr" ]]   || { echo "用法：缺少 --pr <N>" >&2; exit 1; }

# --- 決定要用哪一種 review 設定 ---------------------------------------------
# 不認得的值要直接報錯退出，不要默默 fallback 成 personas：默默 fallback 會讓
# 打錯字的 MRA_BACKTEST_REVIEW_MODE(例如 "presonas")看起來像是成功跑了
# personas 模式，實際上使用者要的是別的設定，而且完全沒有訊號可以發現打錯了。
review_mode="${MRA_BACKTEST_REVIEW_MODE:-personas}"
case "$review_mode" in
  personas)
    mode_args=(--personas) ;;
  standard)
    mode_args=(--strategy standard --provider codex) ;;
  *)
    echo "REVIEW_MODE_INVALID：不認得的 MRA_BACKTEST_REVIEW_MODE 值「${review_mode}」，只接受 standard 或 personas" >&2
    exit 1 ;;
esac

# owner/repo 取 / 後半當 workspace 內的專案名；沒有 / 就直接當專案名用。
project="${repo##*/}"

WS="${MRA_BACKTEST_WORKSPACE:-$HOME/workspace}"
project_dir="${WS}/${project}"
if [[ ! -d "$project_dir" ]]; then
  echo "PROJECT_NOT_FOUND：${project_dir}" >&2
  exit 1
fi

# --- 查 PR 的 base/head SHA -------------------------------------------------
# gh 本身失敗(網路中斷、認證過期、rate limit…)跟「查得到、但這筆 PR 資料裡沒有
# base/head」是兩種不同的失敗，各自要能被獨立診斷，不能共用同一個結束方式。
pr_json="$(gh api "repos/${repo}/pulls/${pr}" 2>/dev/null)"
gh_rc=$?
if [[ $gh_rc -ne 0 ]]; then
  echo "PR_LOOKUP_FAILED：gh api repos/${repo}/pulls/${pr} 失敗(退出碼 ${gh_rc})" >&2
  exit 1
fi

# gh 的 --jq 不接受 --arg，這裡不用 --jq，改用一般的 jq 另外解析。
base_sha="$(printf '%s' "$pr_json" | jq -r '.base.sha // empty' 2>/dev/null)"
head_sha="$(printf '%s' "$pr_json" | jq -r '.head.sha // empty' 2>/dev/null)"
if [[ -z "$base_sha" || -z "$head_sha" ]]; then
  echo "PR_SHA_MISSING：repos/${repo}/pulls/${pr} 沒有 base.sha 或 head.sha" >&2
  exit 1
fi

# --- 確認兩個 commit 本地都在，不在就 fetch 再試 ----------------------------
# base 通常在本地(它是目標分支上的一個歷史 commit)，缺的話用一般的
# `git fetch origin` 補；head 不一樣：PR 一旦合併，來源分支多半已經被刪掉，
# 一般的 `git fetch origin` 用的預設 refspec(+refs/heads/*:refs/remotes/...)
# 完全碰不到它，GitHub 對每個 PR(即使分支刪了)永遠保留 refs/pull/<N>/head
# 這個 ref，必須明講去 fetch 這個 ref 才拿得到 commit 物件。實測
# acme/rails-app-1#4829：plain fetch 前後 head 都不在本地，改成
# `git fetch origin refs/pull/4829/head` 之後才拿到。38 筆候選幾乎全部是
# 已合併、分支已刪的歷史 PR，不這樣做的話這裡幾乎每一筆都會落到
# COMMIT_NOT_LOCAL，run-backtest.sh 會全數 REVIEW_FAILED、最後 ALL_REVIEWS_FAILED。
#
# $1：commit SHA。$2：省略時用一般 fetch 重試(給 base 用)；有給時當成
# refspec 明講去 fetch 這個 ref(給 head 用，帶 refs/pull/<pr>/head)。
_ensure_commit_local() {
  local sha="$1" pull_ref="${2:-}"
  git -C "$project_dir" cat-file -e "${sha}^{commit}" 2>/dev/null && return 0
  if [[ -n "$pull_ref" ]]; then
    git -C "$project_dir" fetch origin "$pull_ref" >/dev/null 2>&1
  else
    git -C "$project_dir" fetch origin >/dev/null 2>&1
  fi
  git -C "$project_dir" cat-file -e "${sha}^{commit}" 2>/dev/null && return 0
  echo "COMMIT_NOT_LOCAL：${sha}" >&2
  return 1
}
_ensure_commit_local "$base_sha" || exit 1
_ensure_commit_local "$head_sha" "refs/pull/${pr}/head" || exit 1

# --- 真正呼叫 mra review ----------------------------------------------------
# 以 workspace 為工作目錄執行；MRA_REVIEW_EMIT_JSON=1 讓 lib/review.sh 直接吐
# review_json 原樣，不渲染、不通知、不動 PKB(見 lib/review.sh 對這個旗標的
# 說明，personas／debate／single-pass 三條路徑都支援)。
#
# MRA_REVIEW_AGENT_MAX_TURNS=40：對齊 pm-workspace-kit 的 reviewEnv
# (packages/cli/src/adapters/mra-review-protocol.ts)，那裡設這個值是為了
# 「rescue PKB-less／large PR 不要在探索中途被砍斷」。基準線沒設的話，等於
# 拿比團隊實際使用時更嚴苛的條件在跑：實測 acme/rails-app-1#4829 就是探索
# db/schema.rb(6489 行，這個 PR 本身只動 34 行)把 turn 預算燒光，被
# per-attempt timeout(MRA_CLAUDE_TIMEOUT_SECONDS)砍斷，review 沒跑完，量到
# 的漏抓率因此偏高，而且原因跟規則本身無關。呼叫端已經設過這個 env 就用
# 呼叫端的值，操作者設的贏。
#
# 刻意不動 MRA_CLAUDE_TIMEOUT_SECONDS：基準線就是要量團隊現在真的會遇到的
# 情況，包含會 timeout 這件事。turn 數上限對齊是因為 gateway 設定本身有設；
# gateway 沒放寬 timeout，這裡也不該偷偷放寬。
range_expr="${base_sha}...${head_sha}"
review_output="$(cd "$WS" && MRA_REVIEW_EMIT_JSON=1 \
  MRA_REVIEW_AGENT_MAX_TURNS="${MRA_REVIEW_AGENT_MAX_TURNS:-40}" \
  bash "$MRA_DIR/bin/mra.sh" review "$project" --range "$range_expr" "${mode_args[@]}")"
review_rc=$?
if [[ $review_rc -ne 0 ]]; then
  echo "REVIEW_CMD_FAILED：mra review ${project} --range ${range_expr} ${mode_args[*]} 退出碼 ${review_rc}" >&2
  exit 1
fi

# 退出碼 0 不代表輸出可用：不是合法 JSON、或沒有 .comments 陣列，都算輸出
# 不合格，跟「指令本身失敗」用不同的 token，才能分辨要往哪裡查。前者是
# mra review 內部某個環節輸出格式壞了，後者是指令整個沒跑完。
if ! printf '%s' "$review_output" | jq -e '(.comments // null) | type == "array"' >/dev/null 2>&1; then
  echo "REVIEW_OUTPUT_INVALID：mra review 輸出不是合法 JSON，或缺少 .comments 陣列" >&2
  exit 1
fi

printf '%s\n' "$review_output"
