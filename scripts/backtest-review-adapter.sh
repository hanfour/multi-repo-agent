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

# --- 回測專用的 mra 設定 ----------------------------------------------------
# config.json 釘住的 review.models.codex = gpt-5.6-luna 跑不完大 PR：
# codex-cli 0.146.0 對長 prompt 會送 prompt_cache_retention，那個 model 回
# invalid_parameter，整次 review 作廢。實測 acme/rails-app-1#4830 燒掉 185,814 個
# token 才失敗。失敗的偏偏是大的 PR(短 prompt 不觸發 prompt caching)，也就是
# 樣本裡最可能有缺陷的那些會系統性缺席，量到的漏抓率因此偏樂觀。
#
# 換成 gpt-5.5 之後又卡 review.codexReasoningEffort = "max"：那個值只有
# gpt-5.6-luna 收，gpt-5.5 的上限是 xhigh，回 unsupported_value。兩個值都在
# 同一個檔裡，而那個檔在版控內、是所有人共用的，不為了回測改它。
#
# personas 模式另一個問題：personas／debate 底下個別 agent 呼叫預設走
# claude(lib/review-personas.sh:59 的 provider 預設值就是 claude)，但共用
# config.json 的 providerMode 是 codex。只改 models.codex 的話，解析出來的
# 那個值(gpt-5.5)會被送去給 claude，claude 不認得那個名字，整批失敗
# (實測：[debate] claude failed: "gpt-5.5" is not a model this version of
# Claude Code recognizes)。standard 模式全程走 codex，沒有這個問題。
#
# 不能用 --provider claude 這個旗標繞過：config.json 的
# review.allowUserOverride: false 會擋掉它(lib/review-provider.sh:58)，除非
# 另外設 MRA_REVIEW_ADMIN_OVERRIDE=1。那是繞過檢查，不是設定，回測不該
# 依賴一個要繞過安全機制才能跑的旗標。正確做法是在衍生 config 裡直接把
# providerMode 設成 claude：那是「這一輪基準線的設定本身」，不是「使用者
# 覆蓋」，不會觸發那道檢查。
#
# 改法：從共用設定衍生一份副本，內容依模式而不同，用 MRA_CONFIG 指過去
# (lib/config.sh:3 的 MRA_CONFIG="${MRA_CONFIG:-$MRA_DIR/config.json}" 讓
# 外部 env 優先)。好處是「這組基準線跑在什麼設定下」變成一個可以直接
# diff 的檔案，階段四要重跑時條件完全可複製。
#
#   standard：只改 models.codex／codexReasoningEffort 這兩個值，
#             providerMode 維持共用設定裡的原值(codex)。
#   personas：把 providerMode 設成 claude、改 models.claude，完全不動
#             models.codex／codexReasoningEffort：這兩個值跟 personas 模式
#             要跑的東西無關，動了反而讓人誤以為 personas 模式也跟 codex
#             設定有關。
#
# 呼叫端已經指定 MRA_CONFIG 就用呼叫端的，不覆蓋，也就不衍生。
codex_model="${MRA_BACKTEST_CODEX_MODEL:-gpt-5.5}"
codex_effort="${MRA_BACKTEST_CODEX_EFFORT:-xhigh}"
claude_model="${MRA_BACKTEST_CLAUDE_MODEL:-sonnet}"
if [[ -z "${MRA_CONFIG:-}" ]]; then
  derived_config="${MRA_BACKTEST_CONFIG_DIR:-${TMPDIR:-/tmp}}/mra-backtest-config.json"
  derived_tmp="${derived_config}.tmp"
  if [[ "$review_mode" == "standard" ]]; then
    if ! jq --arg m "$codex_model" --arg e "$codex_effort" \
         '.review.models.codex = $m | .review.codexReasoningEffort = $e' \
         "$MRA_DIR/config.json" > "$derived_tmp"; then
      echo "CONFIG_DERIVE_FAILED：無法從 ${MRA_DIR}/config.json 產生回測設定" >&2
      rm -f "$derived_tmp"
      exit 1
    fi
  else
    if ! jq --arg cm "$claude_model" \
         '.review.providerMode = "claude" | .review.models.claude = $cm' \
         "$MRA_DIR/config.json" > "$derived_tmp"; then
      echo "CONFIG_DERIVE_FAILED：無法從 ${MRA_DIR}/config.json 產生回測設定" >&2
      rm -f "$derived_tmp"
      exit 1
    fi
  fi
  if ! mv "$derived_tmp" "$derived_config"; then
    echo "CONFIG_PROMOTE_FAILED：無法寫入 ${derived_config}" >&2
    rm -f "$derived_tmp"
    exit 1
  fi
  export MRA_CONFIG="$derived_config"
fi

# --- 回報實際用的執行條件給 run-backtest.sh ---------------------------------
# run-backtest.sh 是呼叫這支 adapter 的父行程，看不到這裡衍生出來、只存在
# 於這個子行程裡的東西。這支 adapter 才是唯一知道「這次實際用了什麼」的
# 地方：自己衍生／解析 config、自己決定 review 模式、自己設 turn 上限、
# 自己做 worktree 隔離。上一版讓 run-backtest.sh 自己用 MRA_CONFIG 沒設
# 就讀共用 $MRA_DIR/config.json 去猜，猜錯了：呼叫端沒有自己指定
# MRA_CONFIG 的常見情況下，上面那個 if 區塊會執行、衍生出一份覆蓋過
# codex model／reasoning effort 的設定，但這份衍生設定只 export 進這個
# 子行程自己的環境，run-backtest.sh 那個父行程永遠看不到，猜出來的值是
# 共用 config.json 的原始值，不是這裡實際會用的值。
#
# MRA_BACKTEST_COND_FILE 有設時，把這些值寫成 JSON 回報；每次呼叫都覆寫
# 同一個檔即可，不用累積(同一輪 --label 底下每個 PR 用的條件本來就一樣)。
# 寫檔失敗只印警告，不影響退出碼：記錄失敗不該讓一次成功的 review 變成
# 回報失敗。
agent_max_turns="${MRA_REVIEW_AGENT_MAX_TURNS:-40}"

# provider／model／reasoning_effort 讀的是這時候已經解出來、真正會生效的
# 那份 $MRA_CONFIG(上面剛衍生出來的，或呼叫端指定、上面那個 if 整個沒執行
# 的都一樣)，不是最前面那幾個「打算要用」的變數：呼叫端自己指定 MRA_CONFIG
# 時，那些變數的值從來沒有真的被套用過，讀它們會回報錯的答案。
#
# provider 看的是 .review.providerMode，不是直接照 $review_mode 硬翻
# (personas→claude、standard→codex)：這樣萬一呼叫端自己指定一份
# providerMode 不是預期值的 MRA_CONFIG，這裡回報的還是實際生效的那個
# provider，不是我們以為一定會是的那個。
effective_provider="$(jq -r '.review.providerMode // empty' "$MRA_CONFIG" 2>/dev/null)"
if [[ "$effective_provider" == "claude" ]]; then
  effective_model="$(jq -r '.review.models.claude // empty' "$MRA_CONFIG" 2>/dev/null)"
  # claude 沒有 reasoning effort 這個概念：不管共用設定裡
  # codexReasoningEffort 填了什麼，都跟這次實際跑的東西無關。故意留空，
  # 下面組 JSON 時轉成明確的 null，不是空字串也不是省略這個鍵。
  effective_reasoning_effort=""
else
  effective_model="$(jq -r '.review.models.codex // empty' "$MRA_CONFIG" 2>/dev/null)"
  effective_reasoning_effort="$(jq -r '.review.codexReasoningEffort // empty' "$MRA_CONFIG" 2>/dev/null)"
fi

# max_turns／synth_max_turns 記的是這個模式「實際生效」的 turn 上限，不是
# $agent_max_turns(MRA_REVIEW_AGENT_MAX_TURNS，預設 40)。那個值只影響
# debate 路徑的 round-1 agent；standard(single-pass)與 personas 這兩條
# 回測會用到的路徑都沒有走 debate，實測 A 組實際跑在
# MRA_REVIEW_STANDARD_MAX_TURNS(預設 6)、C 組實際跑在
# MRA_REVIEW_PERSONA_MAX_TURNS(預設 8，若手動設過就是設的值)，但上一版
# cond 檔兩邊都回報 40。跟先前 codex_model 那次同一類：記錄了一個看起來
# 有意義、實際上不適用的值。下面呼叫 mra 時繼續傳
# MRA_REVIEW_AGENT_MAX_TURNS(對齊 debate 路徑仍然是對的)，只是不能再拿它
# 當這裡要回報的答案。
#
# synth_max_turns 只有 personas 模式才有意義：synthesize 這一步只在
# personas 與 debate 兩條路徑跑，回測只會走到 personas 那條，讀
# MRA_REVIEW_SYNTH_MAX_TURNS(預設 8，見 lib/review-debate-agents.sh)。
# standard 模式沒有 synthesize 這一步，填 JSON null，不是 0 或省略這個鍵。
if [[ "$review_mode" == "standard" ]]; then
  effective_max_turns="${MRA_REVIEW_STANDARD_MAX_TURNS:-6}"
  effective_synth_max_turns=""
else
  effective_max_turns="${MRA_REVIEW_PERSONA_MAX_TURNS:-8}"
  effective_synth_max_turns="${MRA_REVIEW_SYNTH_MAX_TURNS:-8}"
fi

if [[ -n "${MRA_BACKTEST_COND_FILE:-}" ]]; then
  if ! jq -n \
    --arg model "$effective_model" \
    --arg provider "$effective_provider" \
    --arg reasoning_effort "$effective_reasoning_effort" \
    --arg review_mode "$review_mode" \
    --argjson max_turns "$effective_max_turns" \
    --argjson synth_max_turns "${effective_synth_max_turns:-null}" \
    --arg mra_config_path "$MRA_CONFIG" \
    '{model: $model, provider: $provider,
      reasoning_effort: (if $reasoning_effort == "" then null else $reasoning_effort end),
      review_mode: $review_mode, max_turns: $max_turns,
      synth_max_turns: $synth_max_turns,
      worktree_isolated: true, mra_config_path: $mra_config_path}' \
    > "$MRA_BACKTEST_COND_FILE" 2>/dev/null; then
    echo "COND_FILE_WRITE_FAILED：無法寫入執行條件記錄 ${MRA_BACKTEST_COND_FILE}(不影響這次 review 本身的結果)" >&2
  fi
fi

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

# --- worktree 隔離：每個 PR 在自己的 worktree 上跑，不共用 $project_dir ----
# _review_enforce_premises(lib/review-premise.sh)會刪掉「body 提到的 symbol
# 在 repo 找不到」的 finding，查的是 $project_dir 當下 checkout 的那個分支，
# 不是這次 --range 在審的版本。共用工作目錄平常 checkout 在使用者手邊正在做
# 的分支，跟這次要審的歷史 PR head 完全是兩個版本，查錯版本，過濾器就會把
# 「reviewer 抓對了、但當下 checkout 沒有那個 symbol」的 finding 錯殺掉。
# 實測 acme/rails-app-1#4830：reviewer 正確抓到 compress_image 的問題，過濾器因為
# 查的是使用者當下 checkout 的分支(不是 PR#4830 head)找不到這個 symbol，
# 把它刪了，結果是 status=CHANGES_REQUESTED 但 comments:[]。PR 越舊，共用
# 工作目錄跟 PR head 差得越遠，刪得越兇。這是回測方法本身引入的偏差，不是
# 團隊使用時會發生的事(gateway 審的是剛開的 PR，工作目錄本來就是 PR head)。
#
# 用 git worktree 讓每個 PR 各自在一份 checkout 到自己 head 的副本上跑，不
# 關掉 premise 過濾器：worktree 隔離比關掉過濾器更貼近「團隊真的在用的
# 情況」，這是刻意的選擇。
#
# 平行 workspace 根目錄：mra 從 cwd 找 workspace(見 lib/project-path.sh)，
# 呼叫 mra review 時要 cd 到這裡，不是真正的 $WS。
BT_WS="${MRA_BACKTEST_WT_ROOT:-${TMPDIR:-/tmp}/mra-backtest-ws}"
bt_project_dir="$BT_WS/$project"

# 清理一定要綁 trap EXIT：review 跑完不管成功失敗、或中途哪一步提早 exit，
# worktree 都要被移除，不能留給下一次跑到同一個 (repo, pr) 才發現路徑被佔用。
# git worktree remove --force 失敗才退回 rm -rf + prune；這兩步都可能因為
# 檔案系統異常(例如某個檔案被標成不可刪除)而失敗，失敗時只印警告，不
# exit：清理失敗不該讓一次已經成功的 review 變成回報失敗，那樣的假訊號
# 比清理失敗本身更誤導人。
_bt_cleanup() {
  [[ -d "$bt_project_dir" ]] || return 0
  if ! git -C "$project_dir" worktree remove --force "$bt_project_dir" >/dev/null 2>&1; then
    if ! rm -rf "$bt_project_dir" 2>/dev/null; then
      echo "WORKTREE_CLEANUP_FAILED：無法移除 worktree ${bt_project_dir}，需要手動清理(不影響這次 review 本身的結果)" >&2
    fi
    git -C "$project_dir" worktree prune >/dev/null 2>&1
  fi
}
trap _bt_cleanup EXIT

# 自救：建立前先清掉同路徑的殘留(前一次跑到一半被中斷留下的)。這兩步的
# 失敗都不該中止：先試 remove，失敗就 rm -rf，最後一定 prune 一次，把
# git 內部記錄裡指向這個已經不存在路徑的 worktree 項目清掉，不然下一次
# `worktree add` 會因為 git 記得這個路徑而拒絕。
if ! git -C "$project_dir" worktree remove --force "$bt_project_dir" >/dev/null 2>&1; then
  rm -rf "$bt_project_dir" 2>/dev/null
fi
git -C "$project_dir" worktree prune >/dev/null 2>&1

# 複製 workspace 層 metadata：只複製這三個 mra 會讀的檔案，存在才複製，
# 缺了不算錯(全新 workspace 本來就可能還沒有 manual-deps.json)。
if ! mkdir -p "$BT_WS/.collab"; then
  echo "WT_ROOT_MKDIR_FAILED：無法建立 ${BT_WS}/.collab" >&2
  exit 1
fi
for _bt_meta in repos.json dep-graph.json manual-deps.json; do
  [[ -f "$WS/.collab/$_bt_meta" ]] && cp "$WS/.collab/$_bt_meta" "$BT_WS/.collab/$_bt_meta"
done

# 一定要 --detach：這是歷史 PR 的 head，不是要開發的分支，不建分支、不動
# $project_dir 的 HEAD。這支腳本全程都不對 $project_dir 做 checkout／
# switch／reset，worktree 本來就是為了不用碰它才選的。
if ! git -C "$project_dir" worktree add --detach "$bt_project_dir" "$head_sha" >/dev/null 2>&1; then
  echo "WORKTREE_ADD_FAILED：git -C ${project_dir} worktree add --detach ${bt_project_dir} ${head_sha} 失敗" >&2
  exit 1
fi

# 複製 PKB：一定要實體複製，不能 symlink。$project_dir/.mra 被 gitignore，
# 新建的 worktree 不會有；pm-workspace-kit 的規格明講不能 symlink，因為
# mra review 跑完後會回寫 PKB，symlink 會直接污染來源。我們的
# MRA_REVIEW_EMIT_JSON 路徑雖然在回寫之前就 return 了，這裡還是照實體複製
# 做，不要依賴「return 的位置以後也不會變」這個假設。沒有 .mra 就跳過，不
# 算錯(不是每個專案都已經建過 PKB)。
if [[ -d "$project_dir/.mra" ]]; then
  if ! cp -R "$project_dir/.mra" "$bt_project_dir/.mra"; then
    echo "PKB_COPY_FAILED：複製 ${project_dir}/.mra 到 ${bt_project_dir}/.mra 失敗" >&2
    exit 1
  fi
fi

# --- 真正呼叫 mra review：在 worktree 上跑 ----------------------------------
# 以平行 workspace 為工作目錄執行(不是 $WS)；MRA_REVIEW_EMIT_JSON=1 讓
# lib/review.sh 直接吐 review_json 原樣，不渲染、不通知、不動 PKB(見
# lib/review.sh 對這個旗標的說明，personas／debate／single-pass 三條路徑
# 都支援)。
#
# MRA_REVIEW_AGENT_MAX_TURNS(預設 40，見上面「回報實際用的執行條件」那段
# 算出來的 $agent_max_turns，這裡直接沿用，不重算一次避免兩處算出不同的
# 值)：對齊 pm-workspace-kit 的 reviewEnv
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
review_output="$(cd "$BT_WS" && MRA_REVIEW_EMIT_JSON=1 \
  MRA_REVIEW_AGENT_MAX_TURNS="$agent_max_turns" \
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
