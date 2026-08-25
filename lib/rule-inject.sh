#!/usr/bin/env bash
# 把規則注入 persona 的 FOCUS 區塊。這是回測需要的最小機制，完整的三個接點
# 生成是階段四的事。
#
# 出處不進 prompt：那是給人查的，塞進去只是佔 token，而 persona 的 prompt
# 已經要放 diff 與 PKB。
#
# 用可辨識的界線標記（BEGIN/END RULESET）而不是直接 append：注入要能重複執行
# 而不疊加，否則反覆回測會讓 prompt 越長越誇張。
#
# common 層的上限：實測 common 層 81 條規則的完整注入區塊約 80 KB／4 萬
# token，而單一 persona 檔本體只有 729 bytes——不設上限等於在每個 persona
# 前面塞進 110 倍於它本體的內容，乘以 5 persona x 38 PR 更是不成比例。
#
# 上限是 token 預算，不是條數上限：A 路線（TF-IDF）跟 B 路線（taxonomy）
# 在同一個「取前 N 條」上限下，注入的內容量差了 2.9 倍（A 的 common 層
# 81 條規則永遠吃滿上限，B 的 common 層只有 8 條、吃不滿），而 prompt
# 長度本身會影響 review 表現——這會讓兩條路線的回測比較被「prompt 多長」
# 這個變因污染，不是規則品質的公平比較。改成 token 預算後，兩條路線在
# 同一個預算下收斂到接近的注入量，量的落差只反映規則本身的長短，不是
# 條數的落差。
#
# rule_render_block 依 rule_source_count 由大到小逐條累加（出處數相同時用
# id 字典序決定），加上這一條會超過預算就停——不是先取前 N 條再看大小，
# 是先算大小再決定要不要收這一條。不管 N 是多少都固定「至少收一條」，
# 即使第一條本身就超過預算：預算設太小時如果連一條都不收，產出的是空
# 區塊，跟「這層真的沒有規則」外觀上無法分辨。
#
# 預算在「這一層自己的規則」與「common 層規則」之間分配，不是把兩者混在
# 一起排：混排下 common 規則的出處數普遍高於層規則，會把層規則整批擠掉，
# 分層注入因此變成假動作（參數換成 rails 了，prompt 裡卻還是只有 common）。
# 分配方式見 rule_render_block 自己的說明。
#
# token 用「字元數 / 2」粗估，不引入 tokenizer 相依：這是刻意的粗糙估法，
# 目的是讓兩條路線用同一把尺比較，不是產出對任何一個真實 LLM tokenizer
# 都準的數字。兩條路線的規則本文都是同一種語言（中文為主）、同一種格式
# （觸發訊號／判準／反例三段式敘述），用同一個粗估公式時誤差方向一致，
# 不會因為估法本身的系統性偏差讓其中一條路線顯得比較「省」。
#
# 依賴 lib/rule-schema.sh 的 rule_field()／rule_section()／rule_source_count()／
# id_is_safe()。呼叫端要自己 source 它（這支 lib 不 self-source，跟
# rule-schema.sh 對 corpus-targets.sh 的作法一致，見該檔案頭的說明）。

RULE_BLOCK_BEGIN="# --- BEGIN RULESET (auto-generated, do not edit) ---"
RULE_BLOCK_END="# --- END RULESET ---"
RULE_INJECT_DEFAULT_TOKEN_BUDGET=5000

# _rule_entry_text <file> — 組出這條規則要塞進渲染區塊的那一段文字（不含
# BEGIN/END 包裝、不含開頭那句「額外檢查項...」引言）。抽成獨立函式一方面
# 讓 rule_render_block 的累加迴圈保持單純（量測跟組字用同一份文字，不會
# 兩邊算出不一致的大小），另一方面讓測試可以直接量出「這一條規則會占用
# 多少 token」，不用反推整個區塊的大小去猜邊界在哪。
_rule_entry_text() {
  local file="$1" id sev trigger criteria counter
  id="$(rule_field "$file" id)"
  sev="$(rule_field "$file" severity_default)"
  trigger="$(rule_section "$file" 觸發訊號 | tr -d '\r' | sed '/^$/d')"
  criteria="$(rule_section "$file" 判準 | tr -d '\r' | sed '/^$/d')"
  counter="$(rule_section "$file" 反例 | tr -d '\r' | sed '/^$/d')"
  printf '\n- [%s] 預設嚴重度 %s\n  觸發：%s\n  判準：%s\n  不要報：%s\n' \
    "$id" "$sev" "$trigger" "$criteria" "$counter"
}

# _rule_char_count <text> — token 粗估用的字元數。用 wc -m（字元數）而不是
# wc -c（位元組數）：規則內容以中文為主，UTF-8 下一個中文字元是 3 bytes，
# 用位元組數/2 估 token 會把中文內容的 token 數高估將近 3 倍。強制
# LC_ALL=en_US.UTF-8 是為了不依賴呼叫環境剛好把 locale 設成 UTF-8 aware——
# wc -m 在 C locale 下會退化成等同 wc -c；en_US.UTF-8 在多數 macOS/Linux
# 開發機與 CI image 上都有安裝。
_rule_char_count() {
  local n; n="$(LC_ALL=en_US.UTF-8 wc -m <<< "$1")"
  printf '%s' "${n//[[:space:]]/}"
}

# rule_render_block <rules_dir> <layer> [token_budget] — 把某層的規則（該層
# 自己的規則，加上對每層都適用的 common 層）渲染成一段可插入 persona 的
# 文字，總量受 <token_budget> 限制（預設 5000，粗估見上）。
#
# 預算在「層規則」與「common 規則」之間分三輪切，不是把兩者混在一起照出處
# 數排：混排下 common 層規則的出處數普遍高於層規則，實測 tfidf 路線的
# react／vue／nestjs 三層在 5000 預算下層規則 0 條進得去、rails 只進 2 條，
# 分層注入會變成一個假動作——參數換成 rails 了，prompt 裡卻還是只有 common。
#
#   第一輪  層規則先拿預算的一半（保底），照出處數收到裝不下為止。
#   第二輪  common 規則拿「總預算減掉第一輪實際用掉的」，同樣照出處數收。
#   第三輪  層規則還有沒收完的，用前兩輪剩下的額度繼續收。
#
# 保底是雙向的：第三輪的存在讓「層規則沒吃滿的額度退還給 common」與
# 「common 沒吃滿的額度退還給層規則」兩件事同時成立。少了第三輪，一個只有
# 層規則、沒有 common 規則的規則集會平白損失一半預算。
#
# layer 傳 common 時第一輪的候選是空的（common 層規則歸在 common 那一份，
# 不會同時算成層規則），整段退化成「用全部預算收 common」，與分層之前的
# 行為逐字元相同——階段二的基準線因此仍然可比。
#
# 三輪都用 break 而不是 continue：跳過裝不下的、改收後面比較短的規則會變成
# 貪心裝箱，讓入選集合不再是「出處數排名的前綴」，同樣的規則集換一個預算就
# 可能收到完全不同的組合，兩條萃取路線的比較也就不再只反映規則本身。
#
# 規則集是空的、目錄不存在、或這層沒有任何規則時回傳空字串——不是回傳一個
# 沒有內容的 BEGIN/END 區塊，那樣會讓 rule_inject_persona 在 persona 裡插入
# 一段看起來像壞掉的空注入。
rule_render_block() {
  local dir="$1" layer="$2" budget="${3:-$RULE_INJECT_DEFAULT_TOKEN_BUDGET}"
  if [ ! -d "$dir" ]; then
    # 目錄不存在通常是呼叫端傳錯路徑，不是「這層規則真的是空的」——兩者
    # 對外觀察都是回傳空字串，但成因不同，所以還是印出診斷，只是仍然
    # 優雅降級成空規則集，不中止呼叫端。
    printf 'RULE_RENDER_DIR_MISSING\t%s\t規則目錄不存在，視為空規則集\n' "$dir" >&2
    return 0
  fi

  # 0 或負數的預算沒有合理意思：「至少收一條」這個不變式會讓它們仍然收
  # 一條規則進來，不會靜默產出空區塊，但沒有訊號的話，呼叫端會以為自己
  # 設定的極小預算真的生效了，其實是被悄悄忽略、退回預設值——所以連同
  # 非數字、空字串一起，都印出診斷再退回預設。
  case "$budget" in
    ''|*[!0-9]*|0)
      printf 'RULE_BLOCK_BUDGET_INVALID\t%s\t不是正整數，改用預設值 %s\n' \
        "$budget" "$RULE_INJECT_DEFAULT_TOKEN_BUDGET" >&2
      budget="$RULE_INJECT_DEFAULT_TOKEN_BUDGET"
      ;;
  esac

  # 掃一次目錄，湊成「分組<TAB>出處數<TAB>id<TAB>token 數<TAB>檔案路徑」，
  # 分組是 layer（這層自己的規則）或 common。token 數在這裡就算好，讓下面
  # 三輪累加不用對同一條規則重複量測——第一輪與第三輪會走過同一份清單，
  # 兩次算出不同的數字會讓「收了幾條」與「用掉多少預算」對不起來。
  local scanned f
  scanned="$(
    for f in "$dir"/*.md; do
      [ -e "$f" ] || continue
      local l; l="$(rule_field "$f" layer)"
      local bucket
      if [ "$l" = "common" ]; then
        bucket=common
      elif [ "$l" = "$layer" ]; then
        bucket=layer
      else
        continue
      fi
      local id; id="$(rule_field "$f" id)"
      if [ -z "$id" ]; then
        printf 'RULE_RENDER_SKIP_NO_ID\t%s\t沒有 id，略過不注入\n' "$f" >&2
        continue
      fi
      # id 不是用來組路徑（只會被印進渲染文字），所以這裡不是路徑穿越
      # 疑慮；但 id 來自未經清洗的模型輸出，一個帶特殊字元的 id 可能在渲染
      # 文字裡湊出看起來像 BEGIN/END RULESET 界線標記的內容（例如 id 本身
      # 就是 `# --- END RULESET ---` 這種字串），汙染 rule_inject_persona
      # 逐行精確比對的剝除邏輯。這個輸入邊界剛好也是 id_is_safe() 已經在
      # 守的範圍，不需要另外寫一份判斷。
      if ! id_is_safe "$id"; then
        printf 'RULE_RENDER_SKIP_UNSAFE_ID\t%s\t%s\tid 含不安全字元，略過不注入\n' "$f" "$id" >&2
        continue
      fi
      local cnt tok
      cnt="$(rule_source_count "$f")"
      tok=$(( $(_rule_char_count "$(_rule_entry_text "$f")") / 2 ))
      printf '%s\t%s\t%s\t%s\t%s\n' "$bucket" "$cnt" "$id" "$tok" "$f"
    done
  )"
  [ -n "$scanned" ] || return 0

  # 兩份清單各自排序：出處數由大到小（-k2,2nr），同分用 id 字典序
  # （-k3,3）。LC_ALL=C 讓排序結果不受執行環境的 locale 影響，兩條萃取
  # 路線（TF-IDF／taxonomy）比較時才公平。用 awk 分流而不是 grep：grep 在
  # 零筆匹配時退出碼是 1，這裡兩份清單本來就可能是空的（只有 common 規則、
  # 或只有層規則），那是正常狀態，不該讓呼叫端的 set -e 因此中止。
  local layer_ranked common_ranked
  layer_ranked="$(printf '%s\n' "$scanned" \
    | awk -F'\t' '$1 == "layer"' | LC_ALL=C sort -t $'\t' -k2,2nr -k3,3)"
  common_ranked="$(printf '%s\n' "$scanned" \
    | awk -F'\t' '$1 == "common"' | LC_ALL=C sort -t $'\t' -k2,2nr -k3,3)"

  local half=$((budget / 2))
  local used=0 taken=0 n_layer=0 n_common=0
  local bucket cnt id tok file idx

  # 第一輪：層規則保底半數。不管 N 是多少都固定「至少收一條」，即使第一條
  # 本身就超過預算：預算設太小時如果連一條都不收，產出的是空區塊，跟「這層
  # 真的沒有規則」外觀上無法分辨。
  while IFS=$'\t' read -r bucket cnt id tok file; do
    [ -n "$file" ] || continue
    if [ "$taken" -gt 0 ] && [ $((used + tok)) -gt "$half" ]; then
      break
    fi
    used=$((used + tok)); taken=$((taken + 1)); n_layer=$((n_layer + 1))
  done < <(printf '%s\n' "$layer_ranked")

  # 第二輪：common 規則拿總預算扣掉第一輪實際用量之後的額度。「至少收一條」
  # 在這裡的條件是 taken 仍為 0，也就是這層根本沒有層規則——層規則已經收了
  # 東西時就不再無條件塞 common 進來，否則預算會被突破兩次。
  while IFS=$'\t' read -r bucket cnt id tok file; do
    [ -n "$file" ] || continue
    if [ "$taken" -gt 0 ] && [ $((used + tok)) -gt "$budget" ]; then
      break
    fi
    used=$((used + tok)); taken=$((taken + 1)); n_common=$((n_common + 1))
  done < <(printf '%s\n' "$common_ranked")

  # 第三輪：common 沒吃滿的額度退還給層規則。跳過的筆數用序號算，不是比對
  # id：第一輪收的一定是排序清單的前綴（它用 break 停），所以「第
  # first_pass_taken 條之後」就是還沒收的那些，不需要另外維護一個已收集合。
  #
  # 門檻先存進 first_pass_taken 再用，不直接讀 n_layer：n_layer 在這個迴圈裡
  # 會被自己更新，拿它當跳過條件雖然目前算出同樣的結果（idx 與 n_layer 同步
  # 遞增），但那是巧合，不是這段程式碼想表達的意思。
  local first_pass_taken=$n_layer
  idx=0
  while IFS=$'\t' read -r bucket cnt id tok file; do
    [ -n "$file" ] || continue
    idx=$((idx + 1))
    [ "$idx" -gt "$first_pass_taken" ] || continue
    if [ $((used + tok)) -gt "$budget" ]; then
      break
    fi
    used=$((used + tok)); taken=$((taken + 1)); n_layer=$((n_layer + 1))
  done < <(printf '%s\n' "$layer_ranked")

  [ "$taken" -gt 0 ] || return 0

  # 層規則印在前面、common 在後面：兩者都是同一個 FOCUS 區塊的補充，順序
  # 不影響語意，但把針對這個 repo 的那幾條放在前面比較好讀。各自都是排序
  # 清單的前綴，所以 head -n 取出來的順序就是出處數排名。
  local out=""
  if [ "$n_layer" -gt 0 ]; then
    while IFS=$'\t' read -r bucket cnt id tok file; do
      [ -n "$file" ] || continue
      out="${out}$(_rule_entry_text "$file")"
    done < <(printf '%s\n' "$layer_ranked" | head -n "$n_layer")
  fi
  if [ "$n_common" -gt 0 ]; then
    while IFS=$'\t' read -r bucket cnt id tok file; do
      [ -n "$file" ] || continue
      out="${out}$(_rule_entry_text "$file")"
    done < <(printf '%s\n' "$common_ranked" | head -n "$n_common")
  fi

  [ -n "$(printf '%s' "$out" | tr -d '[:space:]')" ] || return 0
  printf '%s\n%s\n%s\n' "$RULE_BLOCK_BEGIN" \
    "額外檢查項（來自團隊規則集，與上面的 FOCUS 並列，不取代它）：${out}" \
    "$RULE_BLOCK_END"
}

# rule_inject_persona <persona_file> <block> <out_file> — 把 <block>（由
# rule_render_block 產生的完整 BEGIN..END 文字，可以是空字串）注入
# <persona_file>，寫到 <out_file>。回傳碼：
#   0 成功
#   1 persona 不存在／舊 RULESET 區塊沒有對應的 END／mv 失敗等硬錯誤
#   2 persona 沒有 FOCUS: 區塊，無法決定注入位置（呼叫端可以選擇原樣複製
#     這個 persona 而不是讓整批處理中止——見 rule_inject_all）
rule_inject_persona() {
  local persona="$1" block="$2" out="$3"
  [ -f "$persona" ] || { printf 'PERSONA_MISSING\t%s\n' "$persona" >&2; return 1; }
  grep -q '^FOCUS:' "$persona" || {
    printf 'PERSONA_NO_FOCUS\t%s\t找不到 FOCUS: 區塊，無法決定注入位置\n' "$persona" >&2
    return 2
  }

  local tmp tmp2
  tmp="$(mktemp "${TMPDIR:-/tmp}/persona-strip.XXXXXX")" || return 1

  # 先剝掉舊的 RULESET 區塊再注入——沒有這步的話重複執行會疊加，反覆回測
  # 會讓 prompt 越長越誇張。
  #
  # 如果只看到 BEGIN 沒看到對應的 END（上一輪注入被中斷，或有人手動改壞
  # 了檔案），寧可整支拒絕注入也不要把 BEGIN 之後的內容（可能包含
  # METHOD／OUTPUT FORMAT）全部靜默吃掉——那是資料遺失，而且不會有任何
  # 訊號讓人發現。
  #
  # 下面插入區塊那段會在 END 標記後面多印一行空白當間距（跟頂層標題隔開）
  # ，但那行空白不在 BEGIN/END 界線之內，單純剝除 BEGIN..END 不會把它一起
  # 拿掉。實測過：不處理這個的話，注入兩次內容不會重複（BEGIN 只出現一
  # 次，冪等測試看起來會過），但每重複注入一輪就會在 END 後面多殘留一行
  # 空白，反覆回測幾輪下來空白行會一直堆積——這是比「內容重複」更隱蔽的
  # 冪等性漏洞，因為單看「BEGIN 只出現一次」這個訊號完全看不出來。所以剝除
  # 時額外多吞掉緊接在 END 後面的那一行空白（如果有的話），跟插入時多印的
  # 那行對稱，兩者相消，注入才是真正跨多輪穩定的冪等操作。
  if ! awk -v b="$RULE_BLOCK_BEGIN" -v e="$RULE_BLOCK_END" '
        $0 == b { skip = 1; after_end = 0; next }
        $0 == e { skip = 0; after_end = 1; next }
        skip { next }
        after_end && $0 == "" { after_end = 0; next }
        { after_end = 0; print }
        END { if (skip) exit 1 }
      ' "$persona" > "$tmp"; then
    printf 'RULESET_STRIP_UNTERMINATED\t%s\t舊的 BEGIN RULESET 沒有對應的 END，拒絕注入以免截斷內容\n' \
      "$persona" >&2
    rm -f "$tmp"
    return 1
  fi

  tmp2="$(mktemp "${TMPDIR:-/tmp}/persona-inject.XXXXXX")" || { rm -f "$tmp"; return 1; }

  if [ -n "$block" ]; then
    # 注入點是 FOCUS 之後、下一個頂層區塊（SCOPE NOTE / METHOD / ...）之
    # 前。不是每個 persona 都有 SCOPE NOTE（例如 test-architect.md 完全
    # 沒有這個區塊），所以錨點是「FOCUS 結束後遇到的下一個頂層標題」而不
    # 是硬找 `^SCOPE NOTE:`——這樣不管下一個區塊是不是 SCOPE NOTE 都能正確
    # 插在 FOCUS 結束的地方，而不是落到檔案最尾端、METHOD 和 OUTPUT
    # FORMAT 之後。
    RULE_BLOCK="$block" awk '
      /^FOCUS:/ { in_focus = 1; print; next }
      in_focus && /^[A-Z][A-Z ]*:/ {
        print ENVIRON["RULE_BLOCK"]
        print ""
        in_focus = 0
        inserted = 1
      }
      { print }
      END { if (in_focus && !inserted) print ENVIRON["RULE_BLOCK"] }
    ' "$tmp" > "$tmp2" || { rm -f "$tmp" "$tmp2"; return 1; }
  else
    # 新渲染出來的規則集是空的（例如這層沒有規則）：只需要確保舊區塊已經
    # 被剝掉（上面已經做了），不要注入空區塊。
    cp "$tmp" "$tmp2" || { rm -f "$tmp" "$tmp2"; return 1; }
  fi

  mv "$tmp2" "$out"
  local mv_rc=$?
  rm -f "$tmp"
  if [ "$mv_rc" -ne 0 ]; then
    printf 'MOVE_FAILED\t%s\n' "$out" >&2
    rm -f "$tmp2"
    return 1
  fi
}

# _rule_inject_personas_with_block <block> <persona_src_dir> <out_dir> — 把
# 一段已經渲染好的規則區塊注入 <persona_src_dir> 底下每個 persona，寫到
# <out_dir>。stdout 一行「<處理總數><TAB><沒有 FOCUS 而原樣複製的數量>」。
#
# 抽成獨立函式是為了讓 rule_inject_all（單層）與 rule_inject_layers（分層，
# 每層各一份 persona 目錄）共用同一份「列 persona、跳過 README、處理沒有
# FOCUS 的情況」的邏輯。分層注入如果自己重寫一份，兩份會漂移；如果改成
# 反覆呼叫 rule_inject_all，同一層的規則會被渲染兩次（一次拿來數條數、
# 一次拿來注入），而渲染是這支 lib 裡最貴的動作。
#
# 遇到「persona 沒有 FOCUS」（rule_inject_persona 回傳 2）不中止整批：這是
# persona 本身的既有結構（例如 test-architect.md 用「KENT BECK 11
# PRINCIPLES:」取代 FOCUS，是真實存在於 agents/personas/ 的檔案，不是壞掉
# 的輸入），原樣複製過去讓它仍然能被 load_persona 讀到，只是少了注入的規
# 則區塊，並在 stderr 印出警告。其他錯誤（persona 不存在、mv 失敗等）仍然
# 視為硬錯誤，整批中止——那些是真正需要人介入的問題，不該被吞掉繼續跑，
# 讓輸出目錄裡缺東西又看不出來哪裡出錯。
_rule_inject_personas_with_block() {
  local block="$1" src="$2" out_dir="$3"
  local p n=0 skipped=0
  for p in "$src"/*.md; do
    [ -e "$p" ] || continue
    [ "$(basename "$p")" = "README.md" ] && continue

    local dest
    dest="$out_dir/$(basename "$p")"
    rule_inject_persona "$p" "$block" "$dest"
    local rc=$?
    if [ "$rc" -eq 2 ]; then
      cp "$p" "$dest"
      local cp_rc=$?
      if [ "$cp_rc" -ne 0 ]; then
        printf 'RULE_INJECT_COPY_FAILED\t%s\n' "$dest" >&2
        return 1
      fi
      printf 'RULE_INJECT_SKIPPED\t%s\t沒有 FOCUS 區塊，原樣複製、未注入規則\n' "$p" >&2
      skipped=$((skipped + 1))
    elif [ "$rc" -ne 0 ]; then
      return 1
    fi
    n=$((n + 1))
  done
  printf '%s\t%s\n' "$n" "$skipped"
}

# _rule_block_rule_count <block> — 一段渲染好的區塊裡有幾條規則。每條規則
# 固定由 `- [<id>] 預設嚴重度 ...` 這一行開起，所以數這種行即可。空區塊
# （這層沒有規則）回傳 0，不是空字串：呼叫端會把它塞進 JSON 的數字欄位。
_rule_block_rule_count() {
  [ -n "$1" ] || { printf '0'; return 0; }
  printf '%s\n' "$1" | grep -c '^- \[' || true
}

# rule_inject_all <rules_dir> <layer> <out_persona_dir> [persona_src_dir]
# [token_budget] — 對每個 persona 各做一次注入。<persona_src_dir> 預設是這支
# lib 所在 repo 的 agents/personas（用 BASH_SOURCE 自己算 repo 根目錄，跟
# lib/*.sh 其他檔案的作法一致，不依賴呼叫端先定義好 MRA_DIR——brief 原本的
# 參考實作直接用 ${MRA_DIR} 卻沒有定義它，這個變數在 lib/*.sh 裡不存在）。
# 第四個參數是額外開的測試用覆蓋點，不影響三參數呼叫的預設行為。
#
# 第五個參數 <token_budget> 轉傳給 rule_render_block（見該函式），省略或傳
# 空字串時完全不改變既有行為——連呼叫 rule_render_block 時都不多帶那個參數，
# 不是傳一個「空字串」進去：rule_render_block 把空字串預算視為畸形輸入，會
# 印 RULE_BLOCK_BUDGET_INVALID 警告再退回預設值，對「呼叫端根本沒打算覆寫」
# 的正常呼叫印出這種警告是誤報。這個參數是 Task 8（帶規則回測）補上的：
# run-rule-backtest.sh 要能覆寫 token 預算並讓它真的傳到 rule_render_block，
# 但這個函式原本沒有任何管道能做到——不透過這裡就得在呼叫端重寫一份
# 「列 persona、跳過 README、處理沒有 FOCUS 的情況」的邏輯，那樣兩份邏輯會
# 漂移。
#
# stdout 仍然只印處理的 persona 數量（一個數字）。跳過的數量走 stderr 的
# RULE_INJECT_SKIPPED，這是既有呼叫端在解析的形狀，不改。
rule_inject_all() {
  local rules_dir="$1" layer="$2" out_dir="$3"
  local this_dir; this_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  local src="${4:-$this_dir/agents/personas}"
  local budget="${5:-}"
  # persona 來源目錄不存在是設定錯誤，不是「剛好沒有 persona」的合法狀態
  # ——跟 rules_dir 不同，這個專案的 persona 目錄本來就該一直存在。悄悄
  # 回傳 n=0 會讓呼叫端誤以為注入完成了、只是零筆，看不出來其實是路徑錯了。
  [ -d "$src" ] || { printf 'RULE_INJECT_PERSONA_SRC_MISSING\t%s\n' "$src" >&2; return 1; }
  mkdir -p "$out_dir" || return 1

  local block
  if [ -n "$budget" ]; then
    block="$(rule_render_block "$rules_dir" "$layer" "$budget")"
  else
    block="$(rule_render_block "$rules_dir" "$layer")"
  fi

  local counts
  counts="$(_rule_inject_personas_with_block "$block" "$src" "$out_dir")" || return 1
  printf '%s\n' "${counts%%$'\t'*}"
}

# rule_inject_layers <rules_dir> <out_root> <layers> [persona_src_dir]
# [token_budget] — 對 <layers>（空白分隔的層名清單）裡的每一層各注入一份
# persona 副本，輸出到 <out_root>/<layer>/。stdout 每層一行：
#
#   <layer><TAB><persona 總數><TAB><沒有 FOCUS 而跳過的數量><TAB><注入的規則條數>
#
# 為什麼要每層一份而不是一份共用的：persona 目錄是 review 流程唯一的載入
# 點（lib/personas.sh 的 _personas_dir()），一次只能指向一個目錄。回測涵蓋
# rails／react／nestjs 三種 repo，要讓 Rails PR 讀到 rails 層的規則、React
# PR 讀到 react 層的，只能先把每層各展開成一份完整的 persona 目錄，再由呼
# 叫端逐 PR 決定 MRA_PERSONAS_DIR 指向哪一份。
#
# 規則條數逐層回報，不是回報 <rules_dir> 底下的檔案總數：那個數字與實際進
# prompt 的內容無關（規則分屬五層，每層只看得到自己這層加 common，而且
# token 預算還會再截斷一次）。記錄一個看起來有意義、實際上不適用的數字，
# 會讓之後重建這輪條件的人以為整份規則集都被測過了。
#
# 任何一層硬失敗就整批中止：分層注入的產出是一組互相對應的目錄，缺一層的
# 話，那一層的 PR 會靜默落回沒有規則的 persona，而回測的 summary 看起來
# 完全正常。
rule_inject_layers() {
  local rules_dir="$1" out_root="$2" layers="$3"
  local this_dir; this_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  local src="${4:-$this_dir/agents/personas}"
  local budget="${5:-}"

  [ -n "$layers" ] || { printf 'RULE_INJECT_NO_LAYERS\t沒有指定任何層\n' >&2; return 1; }
  [ -d "$src" ] || { printf 'RULE_INJECT_PERSONA_SRC_MISSING\t%s\n' "$src" >&2; return 1; }
  mkdir -p "$out_root" || return 1

  local layer
  for layer in $layers; do
    # 層名會直接組成輸出路徑。它的來源是呼叫端的層清單（corpus_layers()），
    # 不是模型輸出，但一個帶 ../ 或 / 的層名會讓注入結果寫到 out_root 之外，
    # 而外觀上跟正常執行沒有差別，所以還是擋在這裡。
    case "$layer" in
      *[!a-z0-9_-]*|'')
        printf 'RULE_INJECT_LAYER_UNSAFE\t%s\t層名只允許小寫英數與 - _\n' "$layer" >&2
        return 1 ;;
    esac

    local out_dir="$out_root/$layer"
    mkdir -p "$out_dir" || return 1

    local block
    if [ -n "$budget" ]; then
      block="$(rule_render_block "$rules_dir" "$layer" "$budget")"
    else
      block="$(rule_render_block "$rules_dir" "$layer")"
    fi

    local counts
    counts="$(_rule_inject_personas_with_block "$block" "$src" "$out_dir")" || return 1
    printf '%s\t%s\t%s\n' "$layer" "$counts" "$(_rule_block_rule_count "$block")"
  done
}
