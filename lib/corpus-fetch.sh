#!/usr/bin/env bash
# GitHub PR review comment 的分頁抓取。
#
# 每頁存成獨立檔案，重跑時跳過已存在且合法的檔，所以 rate limit 或網路中斷後
# 可以直接重跑續抓。打到 rate limit 時停下來印出還剩幾頁，不靜默截斷：2026-06-23
# 的 false-green 就是靜默截斷被當成「沒問題」造成的。

corpus_cache_dir() {
  printf '%s' "${MRA_CORPUS_DIR:-$HOME/.cache/mra-review-corpus}"
}

corpus_repo_dir() {
  local repo="$1"
  printf '%s/%s' "$(corpus_cache_dir)" "${repo//\//__}"
}

corpus_page_file() {
  local repo="$1" page="$2"
  printf '%s/%04d.json' "$(corpus_repo_dir "$repo")" "$page"
}

# 分頁抓取的排序方向。必須是 asc。
#
# 續抓機制把「第 N 頁」當成穩定的鍵：抓過的頁號直接跳過。這個假設只在「新資料
# append 到最後一頁」時成立，也就是 direction=asc。
#
# 用 desc 的話最新的留言永遠排在第 1 頁，只要上次抓完之後有人留了新意見，每一頁
# 的內容都會往後位移：已快取的第 1 到 N-1 頁全部被跳過（新留言因此永遠抓不到），
# 而被擠到新末頁的那批舊留言會再抓一次存進去（因此重複）。corpus_filter_all 沒有
# 依 .id 去重，重複的留言會一路帶進 retention.tsv、前 15 名留言者排名，以及兩條
# 萃取路線的語料。實測 vuejs/core 有 598 頁，一天新增 40 則就是這個形狀。
CORPUS_FETCH_DIRECTION="asc"

# 抓取方向的標記檔。頁號快取只有在「跟當初抓的時候同一個排序方向」下才有意義，
# 方向換了就得整個 repo 重抓。這裡不刪舊檔，而是讓 _corpus_page_cached 判定成
# 未快取，續抓時自然覆寫同名檔案——刪檔會在中途失敗時留下一個比原本更糟的狀態
# （既沒有舊資料，也沒有新資料）。
_corpus_sort_marker() { printf '%s/.sort-direction' "$(corpus_repo_dir "$1")"; }

_corpus_sort_matches() {
  local marker; marker="$(_corpus_sort_marker "$1")"
  [[ -s "$marker" ]] || return 1
  [[ "$(cat "$marker")" == "$CORPUS_FETCH_DIRECTION" ]]
}

# 末頁頁數取自 Link header。沒有 Link header 代表結果只有一頁；但 gh 這次呼叫
# 本身失敗（認證、網路）也會走到同一條「沒有 Link header」的路，兩者不能混為一談：
# 前者是真的單頁 repo，後者是暫時性故障卻被當成「只有 1 頁」蒙混過去——一次
# 抓取失敗會讓 598 頁的 repo 看起來像 1 頁，整輪就這樣「成功」跑完；額度用盡時
# RATE_LIMIT_STOP 印出的「page 1 of 1」也會是錯的，恰好是這個訊息存在的目的。
# 所以要把 gh 呼叫本身的退出碼跟「grep 有沒有找到 Link header」分開檢查：前者
# 失敗直接讓這個函式回傳非 0，不印任何東西；後者找不到才視為單頁。
corpus_last_page() {
  local repo="$1" out link last
  if ! out=$(gh api "repos/$repo/pulls/comments?per_page=100&sort=created&direction=$CORPUS_FETCH_DIRECTION" \
               --include 2>/dev/null); then
    return 1
  fi
  link=$(printf '%s' "$out" | grep -i '^link:') || true
  if [[ -z "${link:-}" ]]; then printf '1'; return 0; fi
  last=$(printf '%s' "$link" | grep -oE 'page=[0-9]+>; rel="last"' | grep -oE '[0-9]+' | head -1)
  printf '%s' "${last:-1}"
}

# 判斷某一頁是不是已經抓過且合法。corpus_fetch_page 用它決定要不要真的打 API；
# corpus_fetch_repo 也要用它，在決定要不要查額度之前就先判斷這頁能不能跳過——
# 已快取的頁不該讓 resume 白付一次 gh api rate_limit 的網路來回。
_corpus_page_cached() {
  local repo="$1" page="$2" out
  # 沒有方向標記的，是改用 asc 之前抓下來的快取：頁號對不上現在的抓法，一律
  # 視為未快取。這樣續抓會把整個 repo 重抓一遍並覆寫，不需要任何手動清理。
  _corpus_sort_matches "$repo" || return 1
  out="$(corpus_page_file "$repo" "$page")"
  [[ -s "$out" ]] && jq -e 'type == "array"' "$out" >/dev/null 2>&1
}

# 退出碼：0 已抓、2 已存在跳過、1 失敗。
#
# 第三個參數 force=1 時忽略快取、一定重抓。asc 排序下最後一頁是「還在長」的
# 那一頁（新留言 append 進去），已快取就跳過的話，兩次抓取之間新增的留言會卡在
# 那一頁裡永遠抓不到。中間的頁滿了 100 筆之後不會再變，可以安全跳過。
corpus_fetch_page() {
  local repo="$1" page="$2" force="${3:-0}" out tmp
  out="$(corpus_page_file "$repo" "$page")"
  if [[ "$force" != "1" ]] && _corpus_page_cached "$repo" "$page"; then
    return 2
  fi
  mkdir -p "$(dirname "$out")"
  # 一定要給 mktemp 明確的 template。macOS/BSD 的 bare `mktemp` 走
  # _CS_DARWIN_USER_TEMP_DIR，完全忽略 TMPDIR（GNU 的會理），所以測試無法把暫存檔
  # 導到自己控制的目錄，「不洩漏暫存檔」那條斷言就會變成永遠 0/0 的空斷言。
  tmp="$(mktemp "${TMPDIR:-/tmp}/corpus.XXXXXX")" || return 1
  if ! gh api "repos/$repo/pulls/comments?per_page=100&page=$page&sort=created&direction=$CORPUS_FETCH_DIRECTION" \
         > "$tmp" 2>/dev/null; then
    rm -f "$tmp"; return 1
  fi
  if ! jq -e 'type == "array"' "$tmp" >/dev/null 2>&1; then
    rm -f "$tmp"; return 1
  fi
  # mv 的退出碼一定要檢查。TMPDIR 與快取目錄常在不同檔案系統上，mv 會退化成
  # copy + unlink，磁碟滿、配額、權限都可能讓它失敗。不檢查的話這裡會回報成功
  # 但快取是空的，而且暫存檔永遠留著。
  if ! mv "$tmp" "$out"; then
    rm -f "$tmp"; return 1
  fi
  # 方向標記在每一頁成功之後重寫一次（內容固定，重寫沒有副作用）。寫失敗要
  # 回報成失敗：標記沒寫成功的話，下一次執行會把這一頁判定成未快取而重抓，
  # 那是浪費，但更糟的是 corpus_check_complete 會擋下整個 repo，而這一頁看起來
  # 明明抓成功了。
  if ! printf '%s\n' "$CORPUS_FETCH_DIRECTION" > "$(_corpus_sort_marker "$repo")"; then
    printf 'SORT_MARKER_WRITE_FAILED\t%s\n' "$repo" >&2
    return 1
  fi
  return 0
}

# GET /rate_limit 本身不計入額度，所以可以放心每頁前查。
# 成功：印出剩餘數並回 0。失敗：不印任何東西並回 1，讓呼叫端能把「額度用盡」
# 和「查不到額度」分開報。舊版失敗時印 0，結果認證失敗會被印成 RATE_LIMIT_STOP，
# 操作者會白等一小時額度重置。
corpus_rate_remaining() {
  local n
  n="$(gh api rate_limit --jq '.resources.core.remaining' 2>/dev/null)" || return 1
  [[ "$n" =~ ^[0-9]+$ ]] || return 1
  printf '%s' "$n"
}

corpus_fetch_repo() {
  local repo="$1" min_rate="${2:-100}"
  local page fetched=0 skipped=0 failed=0 remaining
  # local 與賦值要分開寫才能拿到 corpus_last_page 自己的退出碼：`local last=$(...)`
  # 的退出碼永遠是 local 自己的 0，query 本身失敗這件事會被吃掉。查不到末頁時不能
  # 沿用舊行為「當成 1 頁」再往下跑——那正是這個函式本來要修的假訊號。
  local last
  if ! last="$(corpus_last_page "$repo")"; then
    printf 'LAST_PAGE_UNKNOWN\t%s\n' "$repo"
    return 3
  fi
  for ((page = 1; page <= last; page++)); do
    # 已快取且合法的頁直接跳過，連額度都不查。順序很重要：查額度本身要打一次
    # `gh api rate_limit`（約 0.6 秒的網路來回），resume 時 598 頁裡只缺 6 頁的話，
    # 先查額度再讓 corpus_fetch_page 內部判斷跳過，等於為那 592 頁已快取的頁
    # 各白付一次來回。這裡改成先判斷跳不跳，只有真的要抓的頁才需要查額度。
    # 最後一頁不跳過，理由見 corpus_fetch_page 的 force 參數：asc 排序下它是
    # 還在長的那一頁。
    if [[ "$page" -lt "$last" ]] && _corpus_page_cached "$repo" "$page"; then
      skipped=$((skipped + 1))
      continue
    fi
    # 成功時印出剩餘數並回 0。失敗時不印任何東西並回 1，讓呼叫端能把「額度用盡」
    # 和「查不到額度」分開報。認證失敗或網路不通會被印成 RATE_CHECK_FAILED，
    # 額度用盡則印成 RATE_LIMIT_STOP。兩者訊息不同是因為前者要重新驗證、後者要等額度。
    # 這裡一定要在「確定這頁真的要抓」之後才查，不能為了省事挪到迴圈最前面：
    # 那樣會把已快取的頁又繞回原本要修的問題，額度用盡的守門也不能因此變鬆。
    if ! remaining="$(corpus_rate_remaining)"; then
      printf 'RATE_CHECK_FAILED\t%s\t%s\t%s\n' "$repo" "$page" "$last"
      return 3
    fi
    if [[ "$remaining" -lt "$min_rate" ]]; then
      printf 'RATE_LIMIT_STOP\t%s\t%s\t%s\n' "$repo" "$page" "$last"
      return 3
    fi
    local force=0
    [[ "$page" -eq "$last" ]] && force=1
    corpus_fetch_page "$repo" "$page" "$force"
    case $? in
      0) fetched=$((fetched + 1)) ;;
      2) skipped=$((skipped + 1)) ;;
      *) failed=$((failed + 1)) ;;
    esac
  done
  if [[ "$failed" -gt 0 ]]; then
    # DONE 是成功形狀的一行，failed=N 只是眾多欄位之一，很容易被掃過去 ——
    # 一次實跑漏了 10 頁，DONE 照樣印出來，驗收筆記就照著它寫成「語料完整」。
    # 失敗要有自己的開頭 token，跟 RATE_LIMIT_STOP／RATE_CHECK_FAILED／
    # FILTER_INPUT_INVALID／FILTER_STAGE_FAILED 一致，呼叫端一看開頭就分得出來。
    printf 'FETCH_INCOMPLETE\t%s\t%s\t%s\t%s\n' "$repo" "$fetched" "$last" "$failed"
    return 1
  fi

  # 完整性標記要在印 DONE 之前寫：標記本身寫失敗（磁碟滿、權限）就不能再印
  # 成功形狀的 DONE，那會是同一種「假綠」換一個位置重演。
  local complete_file
  complete_file="$(corpus_repo_dir "$repo")/.complete"
  if ! printf '%s\n' "$last" > "$complete_file"; then
    echo "寫入完整性標記失敗：$complete_file" >&2
    return 1
  fi

  printf 'DONE\t%s\tlast=%s\tfetched=%s\tskipped=%s\tfailed=%s\n' \
    "$repo" "$last" "$fetched" "$skipped" "$failed"
}

# 算快取目錄裡實際存在的頁檔數。用既有的 [0-9]*.json glob，跟篩選階段合併時
# 用的是同一個 pattern；.complete 不是數字開頭，本來就不會被算進去。
_corpus_count_page_files() {
  local dir="$1" pages
  pages=("$dir"/[0-9]*.json)
  if [[ -e "${pages[0]}" ]]; then printf '%s' "${#pages[@]}"; else printf '0'; fi
}

# 篩選前檢查快取完整性：.complete 要存在，而且它記錄的末頁 1..last 每一頁都要在。
# .complete 不是 [0-9]*.json，篩選階段既有的頁面 glob 本來就撿不到它，這裡直接
# 檢查固定路徑，不依賴那個 glob。
#
# 回傳 0 代表完整可用。不完整（含 .complete 根本不存在，或內容不是數字）時印出
# CACHE_INCOMPLETE\t<repo>\t<present>\t<expected>，接著逐行印出缺的頁碼，並回傳 1。
corpus_check_complete() {
  local repo="$1" dir marker last page present missing_pages
  dir="$(corpus_repo_dir "$repo")"
  marker="$dir/.complete"

  # 排序方向不符的快取不能拿去篩選：頁號是用另一種排序抓下來的，內容既有重複
  # 也有缺漏（見 CORPUS_FETCH_DIRECTION 的說明）。頁數看起來是齊的，所以下面
  # 那道逐頁檢查抓不到這件事，要用自己的 token 單獨擋。
  if ! _corpus_sort_matches "$repo"; then
    printf 'CACHE_STALE_SORT\t%s\t%s\t快取是用另一種排序方向抓的，頁號對不上，要重跑一次抓取\n' \
      "$repo" "$(_corpus_count_page_files "$dir")"
    return 1
  fi

  last=""
  if [[ -s "$marker" ]]; then
    last="$(<"$marker")"
  fi
  if [[ ! "$last" =~ ^[0-9]+$ ]]; then
    # 沒有標記，或標記內容壞掉：沒有「應該有幾頁」的依據，expected 老實印成 ?，
    # 不假裝算得出完整比對；present 用現有頁檔數頂替，至少讓操作者看得出快取
    # 裡目前有多少東西。
    printf 'CACHE_INCOMPLETE\t%s\t%s\t%s\n' "$repo" "$(_corpus_count_page_files "$dir")" '?'
    return 1
  fi

  present=0
  missing_pages=()
  for ((page = 1; page <= last; page++)); do
    if [[ -s "$(corpus_page_file "$repo" "$page")" ]]; then
      present=$((present + 1))
    else
      missing_pages+=("$page")
    fi
  done
  if [[ "${#missing_pages[@]}" -eq 0 ]]; then
    return 0
  fi
  printf 'CACHE_INCOMPLETE\t%s\t%s\t%s\n' "$repo" "$present" "$last"
  printf '%s\n' "${missing_pages[@]}"
  return 1
}
