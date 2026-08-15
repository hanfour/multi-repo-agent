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

# 末頁頁數取自 Link header。沒有 Link header 代表結果只有一頁；但 gh 這次呼叫
# 本身失敗（認證、網路）也會走到同一條「沒有 Link header」的路，兩者不能混為一談：
# 前者是真的單頁 repo，後者是暫時性故障卻被當成「只有 1 頁」蒙混過去——一次
# 抓取失敗會讓 598 頁的 repo 看起來像 1 頁，整輪就這樣「成功」跑完；額度用盡時
# RATE_LIMIT_STOP 印出的「page 1 of 1」也會是錯的，恰好是這個訊息存在的目的。
# 所以要把 gh 呼叫本身的退出碼跟「grep 有沒有找到 Link header」分開檢查：前者
# 失敗直接讓這個函式回傳非 0，不印任何東西；後者找不到才視為單頁。
corpus_last_page() {
  local repo="$1" out link last
  if ! out=$(gh api "repos/$repo/pulls/comments?per_page=100&sort=created&direction=desc" \
               --include 2>/dev/null); then
    return 1
  fi
  link=$(printf '%s' "$out" | grep -i '^link:') || true
  if [[ -z "${link:-}" ]]; then printf '1'; return 0; fi
  last=$(printf '%s' "$link" | grep -oE 'page=[0-9]+>; rel="last"' | grep -oE '[0-9]+' | head -1)
  printf '%s' "${last:-1}"
}

# 退出碼：0 已抓、2 已存在跳過、1 失敗。
corpus_fetch_page() {
  local repo="$1" page="$2" out tmp
  out="$(corpus_page_file "$repo" "$page")"
  if [[ -s "$out" ]] && jq -e 'type == "array"' "$out" >/dev/null 2>&1; then
    return 2
  fi
  mkdir -p "$(dirname "$out")"
  # 一定要給 mktemp 明確的 template。macOS/BSD 的 bare `mktemp` 走
  # _CS_DARWIN_USER_TEMP_DIR，完全忽略 TMPDIR（GNU 的會理），所以測試無法把暫存檔
  # 導到自己控制的目錄，「不洩漏暫存檔」那條斷言就會變成永遠 0/0 的空斷言。
  tmp="$(mktemp "${TMPDIR:-/tmp}/corpus.XXXXXX")" || return 1
  if ! gh api "repos/$repo/pulls/comments?per_page=100&page=$page&sort=created&direction=desc" \
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
    # 成功時印出剩餘數並回 0。失敗時不印任何東西並回 1，讓呼叫端能把「額度用盡」
    # 和「查不到額度」分開報。認證失敗或網路不通會被印成 RATE_CHECK_FAILED，
    # 額度用盡則印成 RATE_LIMIT_STOP。兩者訊息不同是因為前者要重新驗證、後者要等額度。
    if ! remaining="$(corpus_rate_remaining)"; then
      printf 'RATE_CHECK_FAILED\t%s\t%s\t%s\n' "$repo" "$page" "$last"
      return 3
    fi
    if [[ "$remaining" -lt "$min_rate" ]]; then
      printf 'RATE_LIMIT_STOP\t%s\t%s\t%s\n' "$repo" "$page" "$last"
      return 3
    fi
    corpus_fetch_page "$repo" "$page"
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
