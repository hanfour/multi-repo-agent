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
# rule_render_block 依 rule_source_count 由大到小只取前 N 條（預設 20），
# 出處數相同時用 id 字典序決定，不依賴 for 迴圈展開 *.md 拿到的檔案系統
# 順序——那個順序不是決定性的，換一台機器就可能不同。
#
# 依賴 lib/rule-schema.sh 的 rule_field()／rule_section()／rule_source_count()／
# id_is_safe()。呼叫端要自己 source 它（這支 lib 不 self-source，跟
# rule-schema.sh 對 corpus-targets.sh 的作法一致，見該檔案頭的說明）。

RULE_BLOCK_BEGIN="# --- BEGIN RULESET (auto-generated, do not edit) ---"
RULE_BLOCK_END="# --- END RULESET ---"
RULE_INJECT_DEFAULT_LIMIT=20

# rule_render_block <rules_dir> <layer> [limit] — 把某層（含 common，對每層
# 都適用）的規則渲染成一段可插入 persona 的文字，依出處數由大到小只取前
# <limit> 條（預設 20，出處數同分用 id 字典序決定）。規則集是空的、目錄不
# 存在、或這層沒有任何規則時回傳空字串——不是回傳一個沒有內容的 BEGIN/END
# 區塊，那樣會讓 rule_inject_persona 在 persona 裡插入一段看起來像壞掉的
# 空注入。
rule_render_block() {
  local dir="$1" layer="$2" limit="${3:-$RULE_INJECT_DEFAULT_LIMIT}"
  if [ ! -d "$dir" ]; then
    # 目錄不存在通常是呼叫端傳錯路徑，不是「這層規則真的是空的」——兩者
    # 對外觀察都是回傳空字串，但成因不同，所以還是印出診斷，只是仍然
    # 優雅降級成空規則集，不中止呼叫端。
    printf 'RULE_RENDER_DIR_MISSING\t%s\t規則目錄不存在，視為空規則集\n' "$dir" >&2
    return 0
  fi

  case "$limit" in
    ''|*[!0-9]*)
      printf 'RULE_BLOCK_LIMIT_INVALID\t%s\t不是非負整數，改用預設值 %s\n' \
        "$limit" "$RULE_INJECT_DEFAULT_LIMIT" >&2
      limit="$RULE_INJECT_DEFAULT_LIMIT"
      ;;
  esac

  # 先湊成「出處數<TAB>id<TAB>檔案路徑」清單再排序取前 N 條：出處數由大到
  # 小（-k1,1nr），同分用 id 字典序（-k2,2）。LC_ALL=C 讓排序結果不受執行
  # 環境的 locale 影響，兩條萃取路線（TF-IDF／taxonomy）比較時才公平。
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

  local out="" cnt id file sev trigger criteria counter
  while IFS=$'\t' read -r cnt id file; do
    [ -n "$file" ] || continue
    sev="$(rule_field "$file" severity_default)"
    trigger="$(rule_section "$file" 觸發訊號 | tr -d '\r' | sed '/^$/d')"
    criteria="$(rule_section "$file" 判準 | tr -d '\r' | sed '/^$/d')"
    counter="$(rule_section "$file" 反例 | tr -d '\r' | sed '/^$/d')"
    out="${out}
- [${id}] 預設嚴重度 ${sev}
  觸發：${trigger}
  判準：${criteria}
  不要報：${counter}
"
  done < <(printf '%s\n' "$ranked" | head -n "$limit")

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

# rule_inject_all <rules_dir> <layer> <out_persona_dir> [persona_src_dir] —
# 對每個 persona 各做一次注入。<persona_src_dir> 預設是這支 lib 所在 repo
# 的 agents/personas（用 BASH_SOURCE 自己算 repo 根目錄，跟 lib/*.sh 其他
# 檔案的作法一致，不依賴呼叫端先定義好 MRA_DIR——brief 原本的參考實作直接
# 用 ${MRA_DIR} 卻沒有定義它，這個變數在 lib/*.sh 裡不存在）。第四個參數
# 是額外開的測試用覆蓋點，不影響三參數呼叫的預設行為。
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
  # persona 來源目錄不存在是設定錯誤，不是「剛好沒有 persona」的合法狀態
  # ——跟 rules_dir 不同，這個專案的 persona 目錄本來就該一直存在。悄悄
  # 回傳 n=0 會讓呼叫端誤以為注入完成了、只是零筆，看不出來其實是路徑錯了。
  [ -d "$src" ] || { printf 'RULE_INJECT_PERSONA_SRC_MISSING\t%s\n' "$src" >&2; return 1; }
  mkdir -p "$out_dir" || return 1

  local block; block="$(rule_render_block "$rules_dir" "$layer")"

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
