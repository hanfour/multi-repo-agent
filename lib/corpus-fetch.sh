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

# 末頁頁數取自 Link header。沒有 Link header 代表結果只有一頁。
corpus_last_page() {
  local repo="$1" link last
  link=$(gh api "repos/$repo/pulls/comments?per_page=100&sort=created&direction=desc" \
           --include 2>/dev/null | grep -i '^link:') || true
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
  tmp="$(mktemp)"
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
  local last page fetched=0 skipped=0 failed=0 remaining
  last="$(corpus_last_page "$repo")"
  for ((page = 1; page <= last; page++)); do
    # 額度查不到時 corpus_rate_remaining 回 0，行為上跟額度用盡一樣要停（fail closed），
    # 但訊息要分得出來：把認證失敗印成 RATE_LIMIT_STOP 會讓操作者白等一小時。
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
  printf 'DONE\t%s\tlast=%s\tfetched=%s\tskipped=%s\tfailed=%s\n' \
    "$repo" "$last" "$fetched" "$skipped" "$failed"
  [[ "$failed" -eq 0 ]]
}
