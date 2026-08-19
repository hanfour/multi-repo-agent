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
# --range base..head(不是 --pr)，用 MRA_REVIEW_EMIT_JSON=1 拿到跟
# backtest_match 期待形狀一致的原始 JSON。
#
# 不加 --no-debate：回測要量的是預設的完整流程(含 debate)，不是精簡過的版本。
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
      # mra review 用不到(--range 已經指定要 review 的範圍)，這裡吃掉、
      # 不轉傳，不當錯誤。
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

# --- 確認兩個 commit 本地都在，不在就 fetch 一次再試 -----------------------
# $1：commit SHA。回測要跑幾十個 PR，每筆都可能碰到 checkout 落後遠端的情況，
# 缺一次不代表壞掉，先 fetch 一次是合理的自救；fetch 完仍然缺，才是真的要
# 停下來、讓操作者知道要處理哪個 SHA。
_ensure_commit_local() {
  local sha="$1"
  git -C "$project_dir" cat-file -e "${sha}^{commit}" 2>/dev/null && return 0
  git -C "$project_dir" fetch origin >/dev/null 2>&1
  git -C "$project_dir" cat-file -e "${sha}^{commit}" 2>/dev/null && return 0
  echo "COMMIT_NOT_LOCAL：${sha}" >&2
  return 1
}
_ensure_commit_local "$base_sha" || exit 1
_ensure_commit_local "$head_sha" || exit 1

# --- 真正呼叫 mra review ----------------------------------------------------
# 以 workspace 為工作目錄執行；MRA_REVIEW_EMIT_JSON=1 讓 lib/review.sh 直接吐
# review_json 原樣，不渲染、不通知、不動 PKB(見 lib/review.sh 對這個旗標的
# 說明)。不加 --no-debate：基準線要量的是預設的完整流程，含 debate。
review_output="$(cd "$WS" && MRA_REVIEW_EMIT_JSON=1 \
  bash "$MRA_DIR/bin/mra.sh" review "$project" --range "${base_sha}..${head_sha}" --personas)"
review_rc=$?
if [[ $review_rc -ne 0 ]]; then
  echo "REVIEW_CMD_FAILED：mra review ${project} --range ${base_sha}..${head_sha} --personas 退出碼 ${review_rc}" >&2
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
