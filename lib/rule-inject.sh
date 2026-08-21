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

# rule_render_block <rules_dir> <layer> [token_budget] — 把某層（含
# common，對每層都適用）的規則渲染成一段可插入 persona 的文字，依出處數
# 由大到小逐條累加，直到加上下一條會超過 <token_budget>（預設 5000，粗估
# 見上）就停；至少收一條，即使第一條就超過預算。規則集是空的、目錄不
# 存在、或這層沒有任何規則時回傳空字串——不是回傳一個沒有內容的 BEGIN/END
# 區塊，那樣會讓 rule_inject_persona 在 persona 裡插入一段看起來像壞掉的
# 空注入。
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

  # 先湊成「出處數<TAB>id<TAB>檔案路徑」清單再排序：出處數由大到小
  # （-k1,1nr），同分用 id 字典序（-k2,2）。LC_ALL=C 讓排序結果不受執行
  # 環境的 locale 影響，兩條萃取路線（TF-IDF／taxonomy）比較時才公平。
  # 不在這裡截斷——token 預算要逐條累加著看才知道在哪裡停，不像純條數
  # 上限可以先 head -n 再處理。
  local ranked f
  ranked="$(
    for f in "$dir"/*.md; do
      [ -e "$f" ] || continue
      local l; l="$(rule_field "$f" layer)"
      [ "$l" = "$layer" ] || [ "$l" = "common" ] || continue
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
      local cnt; cnt="$(rule_source_count "$f")"
      printf '%s\t%s\t%s\n' "$cnt" "$id" "$f"
    done | LC_ALL=C sort -t $'\t' -k1,1nr -k2,2
  )"
  [ -n "$ranked" ] || return 0

  local out="" cnt id file entry entry_tokens tokens_used=0 taken=0
  while IFS=$'\t' read -r cnt id file; do
    [ -n "$file" ] || continue
    entry="$(_rule_entry_text "$file")"
    entry_tokens=$(( $(_rule_char_count "$entry") / 2 ))
    # 只有已經收過至少一條之後，才會因為「加上這條會超預算」而停；第一條
    # 永遠收，不管它自己有多長——見上面「至少收一條」的說明。
    if [ "$taken" -gt 0 ] && [ $((tokens_used + entry_tokens)) -gt "$budget" ]; then
      break
    fi
    out="${out}${entry}"
    tokens_used=$((tokens_used + entry_tokens))
    taken=$((taken + 1))
  done < <(printf '%s\n' "$ranked")

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
# 遇到「persona 沒有 FOCUS」（rule_inject_persona 回傳 2）不中止整批：這是
# persona 本身的既有結構（例如 test-architect.md 用「KENT BECK 11
# PRINCIPLES:」取代 FOCUS，是真實存在於 agents/personas/ 的檔案，不是壞掉
# 的輸入），原樣複製過去讓它仍然能被 load_persona 讀到，只是少了注入的規
# 則區塊，並在 stderr 印出警告。其他錯誤（persona 不存在、mv 失敗等）仍然
# 視為硬錯誤，整批中止——那些是真正需要人介入的問題，不該被吞掉繼續跑，
# 讓輸出目錄裡缺東西又看不出來哪裡出錯。
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

  local p n=0
  for p in "$src"/*.md; do
    [ -e "$p" ] || continue
    [ "$(basename "$p")" = "README.md" ] && continue

    local dest="$out_dir/$(basename "$p")"
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
    elif [ "$rc" -ne 0 ]; then
      return 1
    fi
    n=$((n + 1))
  done
  printf '%s\n' "$n"
}
