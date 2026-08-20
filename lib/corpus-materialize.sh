#!/usr/bin/env bash
# 把篩選後的語料落地成每層一個 JSONL。兩條萃取路線都讀這份，確保它們讀到的
# 是同一份語料 —— 否則比較出來的差異可能來自語料而不是萃取方式。
#
# 輸出用 JSONL 不用 JSON 陣列：語料會到十萬則量級，陣列格式每次讀都要整份
# 進記憶體，JSONL 可以逐行串流。
#
# 續跑用 .done 標記檔，不是看輸出檔存不存在：輸出檔是「某一層」的累積結果，
# 多個 repo 會寫進同一個檔，用它判斷會讓第二個 repo 被跳過。

corpus_materialize_repo() {
  local repo="$1" out_dir="$2"
  local layer
  layer="$(corpus_layer_of "$repo")" || {
    printf 'UNKNOWN_REPO\t%s\t不在 corpus_targets 的清單裡\n' "$repo" >&2
    return 1
  }

  local safe_repo="${repo//\//__}"
  local src_dir="${MRA_CORPUS_DIR:-$HOME/.cache/mra-review-corpus}/${safe_repo}"
  [ -d "$src_dir" ] || {
    printf 'SOURCE_MISSING\t%s\t%s\n' "$repo" "$src_dir" >&2
    return 1
  }

  mkdir -p "$out_dir" || { printf 'OUT_DIR_FAILED\t%s\n' "$out_dir" >&2; return 1; }

  local done_marker="${out_dir}/.done-${safe_repo}"
  if [ -f "$done_marker" ]; then
    cat "$done_marker"
    return 0
  fi

  # 只認頁碼檔（0001.json 這種），不用裸的 *.json：src_dir 底下常常還有
  # scripts/build-corpus.sh 產出的 filtered.json，它已經是投影過的形狀
  # （沒有 .user／.author_association），混進來會在 corpus_filter_bots 的
  # has_login 判斷第一關就被判掉、悄悄貢獻 0 筆——不會算錯，但每次都白跑一次
  # 完整五步篩選，大檔案（TypeScript 的 filtered.json 有 44M）尤其浪費。
  # scripts/build-corpus.sh 自己合併頁面時也是用同一個 glob，這裡延用同一個
  # 做法而不是各寫各的。
  local pages=() page
  for page in "$src_dir"/[0-9]*.json; do
    [ -e "$page" ] || continue
    pages+=("$page")
  done

  if [ ${#pages[@]} -eq 0 ]; then
    printf '%s\n' 0 | tee "$done_marker"
    return 0
  fi

  # 先逐頁驗證合法性，壞頁要指名是哪個檔。這一步跟下面的合併分開做，是因為
  # `jq -s add` 整批吃進去的話，某一頁壞掉只會讓 jq 噴一個泛用的 parse error，
  # 指不出是哪個檔。
  for page in "${pages[@]}"; do
    jq -e 'type == "array"' "$page" >/dev/null 2>&1 || {
      printf 'PAGE_PARSE_FAILED\t%s\t%s\n' "$repo" "$page" >&2
      return 1
    }
  done

  # 一定要先把整個 repo 的所有分頁合併成一個陣列，再對合併結果跑一次
  # corpus_filter_all，不能逐頁各自跑。理由：lib/corpus-filter.sh 第 2 步
  # 「該 repo 留言數前 15 名」是以整個 repo 的留言人口統計出來的，逐頁跑的話
  # 每頁的人口只有 ~100 筆，各頁排出來的前 15 名彼此不同，整個 repo 累加起來
  # 的「前 15 名」集合遠大於 15 人，篩選門檻因此變寬。
  #
  # 這不是理論上的擔心：實測過 TanStack/query（50 頁），逐頁跑總計 2,493
  # 則，合併後跑一次是 1,630 則——跟 retention.tsv 記錄的 n4_prose 對得上的
  # 是合併後這個數字。scripts/build-corpus.sh 本來就是「先合併再篩選一次」
  # （`jq -s 'add' "${pages[@]}"` 之後才呼叫 corpus_filter_all），這裡延用
  # 同一個順序，不要為了少開一個暫存檔就走回頭路。
  local merged
  merged="$(mktemp "${TMPDIR:-/tmp}/corpus-mat-merge.XXXXXX")" || return 1
  if ! jq -s 'add' "${pages[@]}" > "$merged" 2>/dev/null; then
    printf 'PAGE_PARSE_FAILED\t%s\t%s\n' "$repo" "$src_dir" >&2
    rm -f "$merged"
    return 1
  fi

  # 讓 corpus_filter_all 直接把結果寫進暫存檔，不要用 `x="$(corpus_filter_all
  # ...)"` 整份捕進 bash 變數——TypeScript 篩完的結果有 44M，捕進變數要多留一
  # 份記憶體副本，這條路徑本來就要處理 729M 原始語料，沒必要再疊一層浪費。
  local filtered_file
  filtered_file="$(mktemp "${TMPDIR:-/tmp}/corpus-mat-filtered.XXXXXX")" || {
    rm -f "$merged"; return 1;
  }
  corpus_filter_all "$repo" "$layer" < "$merged" > "$filtered_file" 2>/dev/null
  local filter_rc=$?
  rm -f "$merged"
  if [ "$filter_rc" -ne 0 ]; then
    printf 'FILTER_FAILED\t%s\n' "$repo" >&2
    rm -f "$filtered_file"
    return 1
  fi

  local total
  total="$(jq 'length' "$filtered_file")"

  # corpus_filter_all 的輸出已經被 lib/corpus-filter.sh 的 corpus_project 投影
  # 過一次：.user.login 已經改名成 .reviewer、.author_association 已經改名成
  # .association、.html_url 已經改名成 .url。這裡取值一定要用投影後的欄位
  # 名，不能沿用原始 GitHub 欄位名——用 .user.login／.author_association／
  # .html_url 在這個形狀上一律是 null，寫出來的每一行 login/association/
  # html_url 都會悄悄變成 null，但每行仍然是合法 JSON 物件，光看「是不是合法
  # JSON」的檢查完全看不出來。
  local tmp
  tmp="$(mktemp "${TMPDIR:-/tmp}/corpus-mat.XXXXXX")" || {
    rm -f "$filtered_file"; return 1;
  }
  jq -c --arg r "$repo" --arg l "$layer" \
    '.[] | {repo: $r, layer: $l, path, body, diff_hunk, html_url: .url,
            login: .reviewer, association}' "$filtered_file" > "$tmp" || {
    printf 'PROJECT_FAILED\t%s\n' "$repo" >&2
    rm -f "$tmp" "$filtered_file"
    return 1
  }
  rm -f "$filtered_file"

  cat "$tmp" >> "${out_dir}/${layer}.jsonl" || {
    printf 'APPEND_FAILED\t%s\n' "${out_dir}/${layer}.jsonl" >&2
    rm -f "$tmp"
    return 1
  }
  rm -f "$tmp"
  printf '%s\n' "$total" | tee "$done_marker"
}

corpus_materialize_manifest() {
  local out_dir="$1"
  local layer
  for layer in $(corpus_layers); do
    local f="${out_dir}/${layer}.jsonl"
    if [ -s "$f" ]; then
      printf '%s\t%s\t%s\n' "$layer" "$(wc -l < "$f" | tr -d ' ')" \
        "$(jq -r '.repo' "$f" | sort -u | tr '\n' ',' | sed 's/,$//')"
    else
      printf '%s\t0\t\n' "$layer"
    fi
  done
}
