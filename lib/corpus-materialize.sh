#!/usr/bin/env bash
# 把篩選後的語料落地成每層一個 JSONL。兩條萃取路線都讀這份，確保它們讀到的
# 是同一份語料 —— 否則比較出來的差異可能來自語料而不是萃取方式。
#
# 輸出用 JSONL 不用 JSON 陣列：語料會到十萬則量級，陣列格式每次讀都要整份
# 進記憶體，JSONL 可以逐行串流。
#
# 續跑用 .done 標記檔，不是看輸出檔存不存在：輸出檔是「某一層」的累積結果，
# 多個 repo 會寫進同一個檔，用它判斷會讓第二個 repo 被跳過。
#
# 這支函式不是併發安全的：同一個 repo 被兩個行程同時呼叫，兩邊都會在 marker
# 還不存在時通過檢查、各自跑完篩選、各自把資料 append 一次，結果是重複。
# scripts/corpus-materialize.sh 目前對所有 target repo 是嚴格循序處理，不會
# 觸發這個情境；如果之後真的需要平行呼叫，要在「檢查 marker」與「寫入
# marker」之間補上 double-checked locking（拿鎖 → 鎖內重查一次 marker →
# 沒有才繼續）並補上鎖本身的測試（擋住第二個嘗試者、逾時分支、鎖內複查生
# 效），不要只加鎖不加測試——那樣的鎖比沒有更危險：往後的人會信任一個它其實
# 守不住的情境。

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

  # tmp 存這個 repo 這次新產出的 JSONL 行。沒有頁面時是空檔案、total 是 0，
  # 但仍然要走到下面同一套「先寫 marker、再 append layer.jsonl」流程，不要
  # 另開一條捷徑分支——分支一多，其中一條沒跟著改就是下一次事故。
  local tmp
  tmp="$(mktemp "${TMPDIR:-/tmp}/corpus-mat.XXXXXX")" || return 1
  local total=0

  if [ ${#pages[@]} -gt 0 ]; then
    # 先逐頁驗證合法性，壞頁要指名是哪個檔。這一步跟下面的合併分開做，是因為
    # `jq -s add` 整批吃進去的話，某一頁壞掉只會讓 jq 噴一個泛用的 parse
    # error，指不出是哪個檔。
    for page in "${pages[@]}"; do
      jq -e 'type == "array"' "$page" >/dev/null 2>&1 || {
        printf 'PAGE_PARSE_FAILED\t%s\t%s\n' "$repo" "$page" >&2
        rm -f "$tmp"
        return 1
      }
    done

    # 一定要先把整個 repo 的所有分頁合併成一個陣列，再對合併結果跑一次
    # corpus_filter_all，不能逐頁各自跑。理由：lib/corpus-filter.sh 第 2 步
    # 「該 repo 留言數前 15 名」是以整個 repo 的留言人口統計出來的，逐頁跑的話
    # 每頁的人口只有 ~100 筆，各頁排出來的前 15 名彼此不同，整個 repo 累加
    # 起來的「前 15 名」集合遠大於 15 人，篩選門檻因此變寬。
    #
    # 這不是理論上的擔心：實測過 TanStack/query（50 頁），逐頁跑總計 2,493
    # 則，合併後跑一次是 1,630 則——跟 retention.tsv 記錄的 n4_prose 對得上
    # 的是合併後這個數字。scripts/build-corpus.sh 本來就是「先合併再篩選
    # 一次」（`jq -s 'add' "${pages[@]}"` 之後才呼叫 corpus_filter_all），
    # 這裡延用同一個順序，不要為了少開一個暫存檔就走回頭路。
    local merged
    merged="$(mktemp "${TMPDIR:-/tmp}/corpus-mat-merge.XXXXXX")" || { rm -f "$tmp"; return 1; }
    if ! jq -s 'add' "${pages[@]}" > "$merged" 2>/dev/null; then
      printf 'PAGE_PARSE_FAILED\t%s\t%s\n' "$repo" "$src_dir" >&2
      rm -f "$merged" "$tmp"
      return 1
    fi

    # 讓 corpus_filter_all 直接把結果寫進暫存檔，不要用 `x="$(corpus_filter_all
    # ...)"` 整份捕進 bash 變數——TypeScript 篩完的結果有 44M，捕進變數要多留
    # 一份記憶體副本，這條路徑本來就要處理 729M 原始語料，沒必要再疊一層浪費。
    local filtered_file
    filtered_file="$(mktemp "${TMPDIR:-/tmp}/corpus-mat-filtered.XXXXXX")" || {
      rm -f "$merged" "$tmp"; return 1;
    }
    # corpus_filter_all 自己的診斷不能丟掉：它用各自的 token 報
    # FILTER_STAGE_FAILED（還指出是 bots／senior／quality／prose 哪一階段）
    # 與 FILTER_INPUT_INVALID。這裡不能對它的 stderr 做 2>/dev/null——失敗時
    # 只看得到外層自己包的 FILTER_FAILED，查不出是哪一階段炸的，跟
    # lib/corpus-filter.sh 刻意設計「各階段各自報 token」的用意直接相違背。
    # 階段二 run-backtest.sh 對每次 review 呼叫做過同一件事，導致整輪跑完
    # 只拿到一個 0 bytes 的 log、完全查不出失敗原因（後來證實有四種不同
    # 形狀）——這個代價已經付過一次，這裡跟任何子行程呼叫都不能重踩。
    local diag
    diag="$(mktemp "${TMPDIR:-/tmp}/corpus-mat-diag.XXXXXX")" || {
      rm -f "$merged" "$tmp" "$filtered_file"; return 1;
    }
    corpus_filter_all "$repo" "$layer" < "$merged" > "$filtered_file" 2>"$diag"
    local filter_rc=$?
    rm -f "$merged"
    if [ "$filter_rc" -ne 0 ]; then
      printf 'FILTER_FAILED\t%s\n' "$repo" >&2
      cat "$diag" >&2
      rm -f "$filtered_file" "$diag" "$tmp"
      return 1
    fi
    rm -f "$diag"

    # 退出碼一定要接住。$total 會被寫進 .done 標記，而那個標記一旦存在，之後
    # 每次續跑都會短路（直接印出標記內容當筆數）。jq 失敗時 $total 是空字串，
    # 標記就變成一個空行，這個 repo 的筆數從此永遠是空的，也再也不會重跑——
    # 而 corpus_materialize_manifest 要拿它跟各 repo 應有筆數對帳。
    if ! total="$(jq 'length' "$filtered_file")"; then
      printf 'COUNT_FAILED\t%s\t算不出篩選後的筆數\n' "$repo" >&2
      rm -f "$tmp" "$filtered_file"
      return 1
    fi

    # corpus_filter_all 的輸出已經被 lib/corpus-filter.sh 的 corpus_project
    # 投影過一次：.user.login 已經改名成 .reviewer、.author_association 已經
    # 改名成 .association、.html_url 已經改名成 .url。這裡取值一定要用投影
    # 後的欄位名，不能沿用原始 GitHub 欄位名——用 .user.login／
    # .author_association／.html_url 在這個形狀上一律是 null，寫出來的每一行
    # login/association/html_url 都會悄悄變成 null，但每行仍然是合法 JSON
    # 物件，光看「是不是合法 JSON」的檢查完全看不出來。
    jq -c --arg r "$repo" --arg l "$layer" \
      '.[] | {repo: $r, layer: $l, path, body, diff_hunk, html_url: .url,
              login: .reviewer, association}' "$filtered_file" > "$tmp" || {
      printf 'PROJECT_FAILED\t%s\n' "$repo" >&2
      rm -f "$tmp" "$filtered_file"
      return 1
    }
    rm -f "$filtered_file"
  fi

  # ---- 從這裡開始要保證：中斷不會造成資料重複 ------------------------------
  # 先原子寫 marker，marker 成功之後才動 layer.jsonl。不管在哪個時間點被中斷
  # （kill／OOM／斷電），只有兩種結果：
  #   1. marker 還沒寫成功：沒有任何東西被改動，續跑會整個重跑一次，安全。
  #   2. marker 已經寫成功、layer.jsonl 還沒更新完：續跑會看到 marker 存在
  #      而跳過，這個 repo 的資料在 layer.jsonl 裡短少，但不會重複。短少可以
  #      靠跟 retention.tsv 或各 repo 應有筆數比對抓出來；重複不行——兩條
  #      萃取路線會讀到被污染的語料還渾然不覺，而且續跑本身回報成功、不會有
  #      任何錯誤訊息。
  # 反過來做（先 append 再寫 marker）才是問題所在：append 已經完成、marker
  # 還沒寫的中斷點，續跑會重新整個跑一次再 append 一次，同一個 repo 的資料
  # 在 layer.jsonl 裡出現兩次。
  #
  # marker 本身不是裸的 `printf > done_marker`（那不是原子操作，中斷可能
  # 留下寫一半的 marker），是 mktemp 到同一個目錄下再 mv 過去——mv 在同一個
  # 檔案系統上是原子的。
  local marker_tmp
  marker_tmp="$(mktemp "${out_dir}/.done-${safe_repo}.XXXXXX")" || { rm -f "$tmp"; return 1; }
  if ! printf '%s\n' "$total" > "$marker_tmp"; then
    printf 'MARKER_WRITE_FAILED\t%s\t%s\n' "$repo" "$done_marker" >&2
    rm -f "$marker_tmp" "$tmp"
    return 1
  fi
  if ! mv "$marker_tmp" "$done_marker"; then
    printf 'MARKER_WRITE_FAILED\t%s\t%s\n' "$repo" "$done_marker" >&2
    rm -f "$marker_tmp" "$tmp"
    return 1
  fi

  # layer.jsonl 用裸 append，不是「讀舊內容＋mv 蓋過去」：後者曾經是這裡的
  # 寫法，理由是想讓 layer.jsonl 任何時刻都是完整內容、不會是寫到一半的殘破
  # 狀態；但「讀舊內容」這個動作本身在多個行程同時處理同一層的不同 repo 時
  # 不安全——兩邊各自讀到的舊內容都不包含對方還沒 mv 回去的那份，最後 mv 的
  # 那個會讓先 mv 的那份憑空消失（不是重複，是直接遺失，比裸 append 的行為
  # 還要差）。裸 append 沒有這個「讀」的動作，多個行程各自的 write() 呼叫
  # 之間頂多是交錯（interleave），不會讓對方已經寫入的內容整段消失。中斷
  # 造成資料重複的風險已經靠上面「marker 先寫」解決：一旦這裡開始執行，
  # marker 已經確定落地，之後就算被中斷在寫到一半，續跑也只會短路跳過，
  # 不會回頭重新 append 一次。
  local layer_file="${out_dir}/${layer}.jsonl"
  if ! cat "$tmp" >> "$layer_file"; then
    printf 'LAYER_WRITE_FAILED\t%s\t%s\n' "$repo" "$layer_file" >&2
    rm -f "$tmp"
    return 1
  fi
  rm -f "$tmp"

  printf '%s\n' "$total"
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
