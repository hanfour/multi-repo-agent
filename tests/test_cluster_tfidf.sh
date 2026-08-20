#!/usr/bin/env bash
# TF-IDF + average-linkage 分群 (scripts/cluster-tfidf.py)。A 路線的第一步：
# 先分群，再看群裡有什麼。
#
# 前七個案例對應 task-3-brief.md 描述的正常路徑與 brief 自己點名的兩個邊界
# （空輸入、樣本數撐不起下限群數）。後面幾個是自己構造的畸形/邊界輸入——
# 前兩個任務的教訓是：mutation testing 只驗「這行程式碼有作用」，手動構造的
# 畸形輸入才驗「這個函式的定義域涵蓋得夠嗎」。
set -uo pipefail
MRA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/cluster-tfidf-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
IN="$TMP/in"; OUT="$TMP/out"
mkdir -p "$IN" "$OUT"

errors=0; pass=0
ok()   { echo "PASS: $1"; pass=$((pass+1)); }
fail() { echo "FAIL: $1"; errors=$((errors+1)); }
eq()   { if [[ "$2" == "$3" ]]; then ok "$1"; else fail "$1 — expected [$2] got [$3]"; fi; }
has()  { case "$2" in *"$3"*) ok "$1" ;; *) fail "$1 — 沒看到「$3」：$2" ;; esac; }
lacks(){ case "$2" in *"$3"*) fail "$1 — 不該看到「$3」：$2" ;; *) ok "$1" ;; esac; }

# --- brief 的假語料：三組明顯不同主題的意見，每組 6 則，共 18 則 -----------
setup_fake_layer() {
  : > "$IN/nestjs.jsonl"
  local i
  for i in 1 2 3 4 5 6; do
    printf '{"repo":"nestjs/nest","layer":"nestjs","path":"a%s.ts","body":"request scope provider injected into singleton will be promoted","diff_hunk":"@@ scope","html_url":"https://x/%s","login":"u","association":"MEMBER"}\n' "$i" "$i" >> "$IN/nestjs.jsonl"
  done
  for i in 7 8 9 10 11 12; do
    printf '{"repo":"nestjs/nest","layer":"nestjs","path":"b%s.ts","body":"this test mocks the entire service so the assertion never fails","diff_hunk":"@@ spec","html_url":"https://x/%s","login":"u","association":"MEMBER"}\n' "$i" "$i" >> "$IN/nestjs.jsonl"
  done
  for i in 13 14 15 16 17 18; do
    printf '{"repo":"nestjs/nest","layer":"nestjs","path":"c%s.ts","body":"missing await on the async call means errors are swallowed silently","diff_hunk":"@@ async","html_url":"https://x/%s","login":"u","association":"MEMBER"}\n' "$i" "$i" >> "$IN/nestjs.jsonl"
  done
}
setup_fake_layer

# =============================================================================
# 案例 1-7：brief 指定的正常路徑與已點名的邊界
# =============================================================================

test_separates_distinct_topics() {
  python3 "$MRA_DIR/scripts/cluster-tfidf.py" --input "$IN/nestjs.jsonl" \
    --output "$OUT/nestjs-clusters.jsonl" --min-clusters 3 --max-clusters 5
  local n; n="$(wc -l < "$OUT/nestjs-clusters.jsonl" | tr -d ' ')"
  [ "$n" -ge 3 ] && ok "至少分成 3 群（實際 ${n}）" || fail "只分成 $n 群"
}

test_members_stay_within_topic() {
  # 每一群的成員 path 前綴應該一致（a/b/c），混群表示分群失效
  local mixed=0
  while IFS= read -r line; do
    local prefixes
    prefixes="$(printf '%s' "$line" | jq -r '[.members[].path | .[0:1]] | unique | length')"
    [ "$prefixes" -gt 1 ] && mixed=$((mixed + 1))
  done < "$OUT/nestjs-clusters.jsonl"
  eq "沒有跨主題混群" "0" "$mixed"
}

test_deterministic() {
  python3 "$MRA_DIR/scripts/cluster-tfidf.py" --input "$IN/nestjs.jsonl" \
    --output "$OUT/run1.jsonl" --min-clusters 3 --max-clusters 5
  python3 "$MRA_DIR/scripts/cluster-tfidf.py" --input "$IN/nestjs.jsonl" \
    --output "$OUT/run2.jsonl" --min-clusters 3 --max-clusters 5
  if diff -q "$OUT/run1.jsonl" "$OUT/run2.jsonl" >/dev/null; then
    ok "同樣輸入產出完全一致"
  else
    fail "分群結果不可重現"
  fi
}

test_respects_cluster_bounds() {
  python3 "$MRA_DIR/scripts/cluster-tfidf.py" --input "$IN/nestjs.jsonl" \
    --output "$OUT/bounded.jsonl" --min-clusters 2 --max-clusters 4
  local n; n="$(wc -l < "$OUT/bounded.jsonl" | tr -d ' ')"
  [ "$n" -ge 2 ] && [ "$n" -le 4 ] && ok "群數在 2-4 之間（實際 ${n}）" \
    || fail "群數 $n 超出 2-4"
}

test_top_terms_present() {
  local terms
  terms="$(jq -r '.top_terms | join(",")' "$OUT/nestjs-clusters.jsonl" | head -1)"
  [ -n "$terms" ] && ok "有 top_terms（${terms}）" || fail "top_terms 是空的"
}

test_empty_input_fails_loudly() {
  : > "$IN/empty.jsonl"
  local out rc
  out="$(python3 "$MRA_DIR/scripts/cluster-tfidf.py" --input "$IN/empty.jsonl" \
    --output "$OUT/e.jsonl" --min-clusters 3 --max-clusters 5 2>&1)"; rc=$?
  [ "$rc" -ne 0 ] && ok "空輸入退出碼非 0" || fail "應退出非 0"
  has "印出 EMPTY_INPUT" "$out" "EMPTY_INPUT"
}

# 樣本數少於下限時不該硬切 —— 6 則切 15 群等於每群 0.4 則
test_too_few_samples_fails_loudly() {
  head -4 "$IN/nestjs.jsonl" > "$IN/tiny.jsonl"
  local out rc
  out="$(python3 "$MRA_DIR/scripts/cluster-tfidf.py" --input "$IN/tiny.jsonl" \
    --output "$OUT/t.jsonl" --min-clusters 15 --max-clusters 40 2>&1)"; rc=$?
  [ "$rc" -ne 0 ] && ok "樣本不足退出碼非 0" || fail "應退出非 0"
  has "印出 TOO_FEW_SAMPLES" "$out" "TOO_FEW_SAMPLES"
}

# =============================================================================
# 案例 8：cluster() 的 Lance-Williams 遞增更新公式對照獨立寫的暴力參考實作
# =============================================================================
#
# scripts/cluster-tfidf.py 的 cluster() 沒有照 brief 參考實作的寫法（每輪合併
# 重新從頭掃全部群對算 group_sim）——O(n^3) 在 n=400 實測要 12.6 秒，外插到
# 每層抽樣上限 2000 則會落在 26 分鐘量級，改用 Lance-Williams 遞增更新公式
# （見 cluster() 的 docstring 推導）換掉重新計算的部分。這個公式數學上等價，
# 但「數學上等價」跟「程式碼沒寫錯」是兩回事——上面 test_separates_distinct_
# topics 等既有案例全部無法分辨「用正確加權平均」跟「用不加權的普通平均」
# 這兩種寫法：因為那些案例裡第一次合併永遠是兩個單則群（權重 1 比 1），
# 加權跟不加權在那個當下沒有差異，只有「群跟群」合併（其中一群已經不是
# 單則）之後才會分岔——已經實測驗證過這個 MISSED（見 task-3-report.md）。
#
# 這裡直接對照一個獨立寫的暴力版本（brief 原本那種「每輪重新算」的寫法，
# 寫在這支測試檔裡，不 import 任何 production 程式碼的 cluster 邏輯）。
#
# 一開始用隨機浮點相似度矩陣試過，結果不可靠：bruteforce 是「每次都從原始
# 配對重新加總取平均」，Lance-Williams 是「用已經算好的群平均遞增合併」，
# 兩種計算順序在數學上等價，但浮點數加法不滿足結合律，兩邊在小數點 15 位
# 後可能有極微小差異——多數情況差異小到不影響「哪一對最相似」的排序，但
# 隨機矩陣裡經常出現彼此非常接近的候選配對，這種時候浮點雜訊就足以讓兩邊
# 選到不同的合併順序，整棵合併樹分岔，卻不代表加權公式本身寫錯（拿掉
# 加權、改成不加權平均的錯誤版本去測，分岔率幾乎一樣高——這是實際測過的，
# 不是猜測，見 task-3-report.md 對這段調查過程的記錄）。
#
# 改用手動設計、彼此差距夠大（>20 倍浮點誤差量級）的整數權重矩陣，只在
# 「加權 vs 不加權」這一個變因上製造分岔，其餘每一步的勝負都留足安全邊際。
# 5 個點、目標 2 群、3 次合併：
#   步驟 1：(0,1) 相似度 10000，遠高於其他，明確合併成 G（size 2）。
#   步驟 2：(G,2) 相似度 2500，遠高於其他，明確合併成 H（size 3）。
#   步驟 3（唯一牽涉不等大小群、加權才會分岔的地方）：
#     weighted：sim(H,3) = (2*400 + 1*0)/3 ≈ 266.67 > sim(H,4) = 225
#       → H 跟 3 合併，4 落單。
#     unweighted（拿掉加權的錯誤版本）：sim(H,3) = (400+0)/2 = 200
#       < sim(H,4) = 225 → H 跟 4 合併，3 落單。
# 兩種寫法在步驟 3 選了不同的合併對象，且差距（266.67 對 225 對 200）遠大於
# 浮點誤差，不是巧合 tie。這個案例已經對兩邊都實測驗證過（見報告）。
test_lance_williams_matches_bruteforce_reference() {
  local out
  out="$(python3 - "$MRA_DIR/scripts/cluster-tfidf.py" <<'PY'
import importlib.util
import sys

prod_path = sys.argv[1]
spec = importlib.util.spec_from_file_location("cluster_tfidf_prod", prod_path)
prod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(prod)

N = 5
TARGET = 2
# 整數權重：cosine(vecs[i], vecs[j]) = w*w 是精確整數，不經過任何無理數
# 捨入（不像 sqrt(sim) 重建那樣會引入浮點誤差）。
W = {
    (0, 1): 100,
    (0, 2): 50, (1, 2): 50,
    (0, 3): 20, (1, 3): 20, (2, 3): 0,
    (0, 4): 15, (1, 4): 15, (2, 4): 15,
    (3, 4): 1,
}

def make_vecs(n, w):
    vecs = [dict() for _ in range(n)]
    dim = 0
    for i in range(n):
        for j in range(i + 1, n):
            weight = float(w[(i, j)])
            vecs[i][dim] = weight
            vecs[j][dim] = weight
            dim += 1
    return vecs

def bruteforce_cluster(vecs, target):
    """brief 原本的參考寫法：每輪合併重新從頭掃全部群對，O(n^3)。跟
    production 的 cluster() 完全獨立寫，不共用任何程式碼。"""
    groups = [[i] for i in range(len(vecs))]
    sim = {}
    for i in range(len(vecs)):
        for j in range(i + 1, len(vecs)):
            sim[(i, j)] = prod.cosine(vecs[i], vecs[j])

    def group_sim(g1, g2):
        pairs = [(min(a, b), max(a, b)) for a in g1 for b in g2]
        return sum(sim[p] for p in pairs) / len(pairs)

    while len(groups) > target:
        best, best_pair = None, None
        for i in range(len(groups)):
            for j in range(i + 1, len(groups)):
                s = group_sim(groups[i], groups[j])
                if best is None or s > best or (s == best and (i, j) < best_pair):
                    best, best_pair = s, (i, j)
        i, j = best_pair
        groups[i] = sorted(groups[i] + groups[j])
        del groups[j]
    return sorted(groups, key=lambda g: (-len(g), g[0]))

vecs = make_vecs(N, W)
prod_result = prod.cluster(vecs, TARGET)
ref_result = bruteforce_cluster(vecs, TARGET)

if prod_result == ref_result:
    print(f"GROUPS_EQUAL\t{prod_result}")
else:
    print(f"GROUPS_DIFFER\tprod={prod_result}\tref={ref_result}")
PY
)"
  # 注意："GROUPS_DIFFER" 不含 "GROUPS_EQUAL" 這個子字串，has／lacks 才有
  # 辨別力——早先用 MATCH／MISMATCH 當 token 時，"MISMATCH" 本身就包含
  # "MATCH" 子字串，has "MATCH" 那個斷言不管兩邊吻不吻合恆為真，等於沒測。
  #
  # 不額外斷言輸出裡有沒有 "[0, 1, 2, 3]" 這個具體分群結果：分岔時 Python
  # 印出的訊息會同時包含 prod= 和 ref= 兩段，"[0, 1, 2, 3]" 這個子字串仍然
  # 會出現在 ref= 那一段裡，has 斷言測不出「prod 自己算錯」——已經實測踩過
  # 這個坑（見 task-3-report.md），所以只留下面兩個真的有辨別力的斷言。
  has "Lance-Williams 遞增更新與獨立暴力參考實作分出完全一致的群" "$out" "GROUPS_EQUAL"
  lacks "沒有 GROUPS_DIFFER" "$out" "GROUPS_DIFFER"
}

# =============================================================================
# 案例 9-16：自己構造的畸形/邊界輸入
# =============================================================================

# body/diff_hunk 是 null 或空字串或整個欄位缺席，混雜在同一份輸入裡。
# tokenize() 靠 `(r.get(...) or "")` 擋 None，這裡直接對著三種變體實測，
# 而不是相信「看起來會擋住」。
test_null_and_empty_body_fields_do_not_crash() {
  : > "$IN/nullfields.jsonl"
  printf '{"repo":"r","layer":"nestjs","path":"n1.ts","body":null,"diff_hunk":"@@ real diff content here","html_url":"https://x/n1","login":"u","association":"MEMBER"}\n' >> "$IN/nullfields.jsonl"
  printf '{"repo":"r","layer":"nestjs","path":"n2.ts","body":"","diff_hunk":null,"html_url":"https://x/n2","login":"u","association":"MEMBER"}\n' >> "$IN/nullfields.jsonl"
  printf '{"repo":"r","layer":"nestjs","path":"n3.ts","body":"real body content words here","html_url":"https://x/n3","login":"u","association":"MEMBER"}\n' >> "$IN/nullfields.jsonl"
  printf '{"repo":"r","layer":"nestjs","path":"n4.ts","body":null,"diff_hunk":null,"html_url":"https://x/n4","login":"u","association":"MEMBER"}\n' >> "$IN/nullfields.jsonl"
  printf '{"repo":"r","layer":"nestjs","path":"n5.ts","body":"another normal body with words","diff_hunk":"@@ x","html_url":"https://x/n5","login":"u","association":"MEMBER"}\n' >> "$IN/nullfields.jsonl"
  printf '{"repo":"r","layer":"nestjs","path":"n6.ts","body":"","diff_hunk":"","html_url":"https://x/n6","login":"u","association":"MEMBER"}\n' >> "$IN/nullfields.jsonl"
  local out rc
  out="$(python3 "$MRA_DIR/scripts/cluster-tfidf.py" --input "$IN/nullfields.jsonl" \
    --output "$OUT/nullfields.jsonl" --min-clusters 2 --max-clusters 3 2>&1)"; rc=$?
  eq "null/空/缺席欄位混雜不崩潰，退出碼 0" "0" "$rc"
  lacks "沒有 Python traceback" "$out" "Traceback"
  local n; n="$(wc -l < "$OUT/nullfields.jsonl" | tr -d ' ')"
  [ "$n" -ge 2 ] && [ "$n" -le 3 ] && ok "群數仍在界限內（實際 ${n}）" \
    || fail "群數 $n 超出 2-3"
}

# 全部文件的 token 完全相同：df[t] == n for every t，idf = log(n/(n+1))
# 是非零負值（不是零，因為 df 對每個詞來說是 n 不是 n-1）——這個案例真正測
# 的是決定性，不是除以零：每個向量彼此 cosine 都恰好是 1.0（tie 最極端的
# 情況），驗證極端 tie 之下 tie-break 仍然完全決定性（靠 (i, j) 字典序）。
# 真正會讓 TF-IDF 除以零的是另一個案例（見下面 test_zero_idf_document_
# does_not_divide_by_zero）：詞出現在剛好 n-1 篇文件時 idf 才會等於 0。
test_identical_tokens_do_not_divide_by_zero() {
  : > "$IN/identical.jsonl"
  local i
  for i in 1 2 3 4 5 6; do
    printf '{"repo":"r","layer":"nestjs","path":"i%s.ts","body":"identical wording every single document shares","diff_hunk":"@@ identical diff content shared too","html_url":"https://x/i%s","login":"u","association":"MEMBER"}\n' "$i" "$i" >> "$IN/identical.jsonl"
  done
  local out1 out2 rc1 rc2
  out1="$(python3 "$MRA_DIR/scripts/cluster-tfidf.py" --input "$IN/identical.jsonl" \
    --output "$OUT/identical1.jsonl" --min-clusters 2 --max-clusters 3 2>&1)"; rc1=$?
  out2="$(python3 "$MRA_DIR/scripts/cluster-tfidf.py" --input "$IN/identical.jsonl" \
    --output "$OUT/identical2.jsonl" --min-clusters 2 --max-clusters 3 2>&1)"; rc2=$?
  eq "全同 token 的語料不崩潰，退出碼 0" "0" "$rc1"
  lacks "沒有除以零的例外（ZeroDivisionError）" "$out1" "ZeroDivisionError"
  lacks "沒有 Python traceback" "$out1" "Traceback"
  eq "第二次跑也是退出碼 0" "0" "$rc2"
  lacks "第二次跑也沒有除以零的例外" "$out2" "ZeroDivisionError"
  if diff -q "$OUT/identical1.jsonl" "$OUT/identical2.jsonl" >/dev/null; then
    ok "全同 token、最極端的 tie 之下仍然決定性"
  else
    fail "全同 token 時分群結果不可重現（tie-break 沒有真的決定性）"
  fi
}

# 真正會讓 TF-IDF 除以零的情境：一個詞恰好出現在 n-1 篇文件裡時，
# idf = log(n/(1+(n-1))) = log(n/n) = log(1) = 0。如果某篇文件的全部
# token 剛好都只有這個 idf=0 的詞，那篇文件的向量權重全部是 0，
# sum(x*x) = 0，sqrt(0) = 0 —— 之後正規化那一步 `x / norm` 沒有
# `or 1.0` 防呆的話就是真的 0.0/0.0，會拋 ZeroDivisionError。
# （單純「全部文件 token 完全相同」不會踩到這裡，因為那樣 df 是 n 不是
# n-1，idf 是非零負值——這是先跑過才確認的，不是憑空推論。）
test_zero_idf_document_does_not_divide_by_zero() {
  : > "$IN/zeroidf.jsonl"
  # commonword 出現在 6 篇裡的 5 篇（缺第 6 篇），df=5，n=6 →
  # idf = log(6/6) = 0。第 1 篇的內文只有 commonword 這一個詞，
  # 整篇向量的權重因此全部是 0。
  printf '{"repo":"r","layer":"nestjs","path":"z1.ts","body":"commonword","diff_hunk":"","html_url":"https://x/z1","login":"u","association":"MEMBER"}\n' >> "$IN/zeroidf.jsonl"
  printf '{"repo":"r","layer":"nestjs","path":"z2.ts","body":"commonword extra padding words here for row two","diff_hunk":"","html_url":"https://x/z2","login":"u","association":"MEMBER"}\n' >> "$IN/zeroidf.jsonl"
  printf '{"repo":"r","layer":"nestjs","path":"z3.ts","body":"commonword extra padding words here for row three","diff_hunk":"","html_url":"https://x/z3","login":"u","association":"MEMBER"}\n' >> "$IN/zeroidf.jsonl"
  printf '{"repo":"r","layer":"nestjs","path":"z4.ts","body":"commonword extra padding words here for row four","diff_hunk":"","html_url":"https://x/z4","login":"u","association":"MEMBER"}\n' >> "$IN/zeroidf.jsonl"
  printf '{"repo":"r","layer":"nestjs","path":"z5.ts","body":"commonword extra padding words here for row five","diff_hunk":"","html_url":"https://x/z5","login":"u","association":"MEMBER"}\n' >> "$IN/zeroidf.jsonl"
  printf '{"repo":"r","layer":"nestjs","path":"z6.ts","body":"totally unrelated vocabulary in this final row","diff_hunk":"","html_url":"https://x/z6","login":"u","association":"MEMBER"}\n' >> "$IN/zeroidf.jsonl"
  local out rc
  out="$(python3 "$MRA_DIR/scripts/cluster-tfidf.py" --input "$IN/zeroidf.jsonl" \
    --output "$OUT/zeroidf.jsonl" --min-clusters 2 --max-clusters 3 2>&1)"; rc=$?
  eq "idf=0 的文件不崩潰，退出碼 0" "0" "$rc"
  lacks "沒有除以零的例外（ZeroDivisionError）" "$out" "ZeroDivisionError"
  lacks "沒有 Python traceback" "$out" "Traceback"
  local n; n="$(wc -l < "$OUT/zeroidf.jsonl" | tr -d ' ')"
  [ "$n" -ge 2 ] && [ "$n" -le 3 ] && ok "idf=0 文件存在時群數仍在界限內（實際 ${n}）" \
    || fail "群數 $n 超出 2-3"
}

# 只有一則：任何 min-clusters >= 1 都撐不起「每群至少 3 則」的下限，
# 應該落在 TOO_FEW_SAMPLES，而不是嘗試把 1 筆硬分成 1 群。
test_single_record_reports_too_few_samples() {
  printf '{"repo":"r","layer":"nestjs","path":"only.ts","body":"the one and only record in this file","diff_hunk":"@@ solo","html_url":"https://x/only","login":"u","association":"MEMBER"}\n' > "$IN/single.jsonl"
  local out rc
  out="$(python3 "$MRA_DIR/scripts/cluster-tfidf.py" --input "$IN/single.jsonl" \
    --output "$OUT/single.jsonl" --min-clusters 1 --max-clusters 1 2>&1)"; rc=$?
  [ "$rc" -ne 0 ] && ok "單一筆退出碼非 0" || fail "應退出非 0"
  has "印出 TOO_FEW_SAMPLES" "$out" "TOO_FEW_SAMPLES"
  [ -f "$OUT/single.jsonl" ] && fail "失敗時不該留下輸出檔" \
    || ok "失敗時沒有留下輸出檔"
}

# 群數上下限互相矛盾（min > max）：brief 的參考公式
# `max(min_clusters, min(max_clusters, ...))` 在 min > max 時會讓 max
# 形同虛設、悄悄以 min 為準——這種輸入應該直接報錯，不是默默選一個值。
test_contradictory_bounds_fail_loudly() {
  local out rc
  out="$(python3 "$MRA_DIR/scripts/cluster-tfidf.py" --input "$IN/nestjs.jsonl" \
    --output "$OUT/contradictory.jsonl" --min-clusters 10 --max-clusters 5 2>&1)"; rc=$?
  [ "$rc" -ne 0 ] && ok "min > max 退出碼非 0" || fail "應退出非 0"
  has "印出 INVALID_CLUSTER_BOUNDS" "$out" "INVALID_CLUSTER_BOUNDS"
  [ -f "$OUT/contradictory.jsonl" ] && fail "失敗時不該留下輸出檔" \
    || ok "失敗時沒有留下輸出檔"
}

# JSONL 有一行壞掉：其餘行都合法，但中間混了一行不是合法 JSON。
# 應該指名是哪個檔案壞的，而不是吞掉、也不是產出半份結果。
test_malformed_jsonl_line_fails_loudly() {
  : > "$IN/broken.jsonl"
  printf '{"repo":"r","layer":"nestjs","path":"ok1.ts","body":"a fine first record with real words","diff_hunk":"@@ x","html_url":"https://x/ok1","login":"u","association":"MEMBER"}\n' >> "$IN/broken.jsonl"
  printf 'this is not json at all {{{\n' >> "$IN/broken.jsonl"
  printf '{"repo":"r","layer":"nestjs","path":"ok2.ts","body":"a fine third record with real words","diff_hunk":"@@ y","html_url":"https://x/ok2","login":"u","association":"MEMBER"}\n' >> "$IN/broken.jsonl"
  local out rc
  out="$(python3 "$MRA_DIR/scripts/cluster-tfidf.py" --input "$IN/broken.jsonl" \
    --output "$OUT/broken.jsonl" --min-clusters 2 --max-clusters 3 2>&1)"; rc=$?
  [ "$rc" -ne 0 ] && ok "壞掉的 JSONL 行退出碼非 0" || fail "應退出非 0"
  has "指名是哪個檔壞的" "$out" "broken.jsonl"
  [ -f "$OUT/broken.jsonl" ] && fail "壞行時不該留下輸出檔" \
    || ok "壞行時沒有留下輸出檔"
}

# 全部文件的 token 都被 tokenize() 濾光（只有停用詞或太短的字），vocab 是
# 空的、每個向量都是空字典。cosine(空,空) 應該是 0.0 而不是例外，
# top_terms 應該是空陣列而不是 IndexError。
test_all_stopword_vocab_produces_empty_top_terms_without_crash() {
  : > "$IN/stopwords.jsonl"
  local i
  for i in 1 2 3 4 5 6; do
    printf '{"repo":"r","layer":"nestjs","path":"s%s.ts","body":"the this that for are and not you","diff_hunk":"@@ an is it ok","html_url":"https://x/s%s","login":"u","association":"MEMBER"}\n' "$i" "$i" >> "$IN/stopwords.jsonl"
  done
  local out rc
  out="$(python3 "$MRA_DIR/scripts/cluster-tfidf.py" --input "$IN/stopwords.jsonl" \
    --output "$OUT/stopwords.jsonl" --min-clusters 2 --max-clusters 3 2>&1)"; rc=$?
  eq "空 vocab 不崩潰，退出碼 0" "0" "$rc"
  lacks "沒有 IndexError" "$out" "IndexError"
  lacks "沒有 Python traceback" "$out" "Traceback"
  local n; n="$(wc -l < "$OUT/stopwords.jsonl" | tr -d ' ')"
  [ "$n" -ge 2 ] && [ "$n" -le 3 ] && ok "空 vocab 時群數仍在界限內（實際 ${n}）" \
    || fail "群數 $n 超出 2-3"
}

# --sample-cap 的等距抽樣公式本身：k = 總數 // cap，取索引 0、k、2k…。
# 假語料規模都不到 2000 上限，用小 cap 直接測公式，而不是只信任「看起來對」。
# 9 筆、cap=3 → k=3 → 應該取到第 1、4、7 筆（0-index 的 0、3、6）。
test_sample_cap_takes_equidistant_records() {
  : > "$IN/sampling.jsonl"
  local i
  for i in 1 2 3 4 5 6 7 8 9; do
    printf '{"repo":"r","layer":"nestjs","path":"s%s.ts","body":"sampling probe record number %s with distinct filler words","diff_hunk":"@@ s%s","html_url":"https://x/s%s","login":"u","association":"MEMBER"}\n' "$i" "$i" "$i" "$i" >> "$IN/sampling.jsonl"
  done
  local out rc
  out="$(python3 "$MRA_DIR/scripts/cluster-tfidf.py" --input "$IN/sampling.jsonl" \
    --output "$OUT/sampling.jsonl" --min-clusters 1 --max-clusters 1 --sample-cap 3 2>&1)"; rc=$?
  eq "抽樣後仍成功，退出碼 0" "0" "$rc"
  has "印出抽樣前後筆數 9 → 3" "$out" "9 則 → 等距抽樣 → 3 則"
  local paths
  paths="$(jq -r '.members[].path' "$OUT/sampling.jsonl" | sort)"
  eq "抽到的是第 1、4、7 筆（0-index 的 0、3、6），不是任意 3 筆" \
    "$(printf 's1.ts\ns4.ts\ns7.ts')" "$paths"
}

# =============================================================================
# 案例 17-18：code review 要求新增的測試
# =============================================================================

# min-clusters < 1 時應該報結構化錯誤，而不是拋裸 traceback。
test_min_clusters_below_one_fails_loudly() {
  local out rc
  out="$(python3 "$MRA_DIR/scripts/cluster-tfidf.py" --input "$IN/nestjs.jsonl" \
    --output "$OUT/negative.jsonl" --min-clusters 0 --max-clusters 1 2>&1)"; rc=$?
  [ "$rc" -ne 0 ] && ok "min-clusters < 1 退出碼非 0" || fail "應退出非 0"
  has "印出 INVALID_CLUSTER_BOUNDS" "$out" "INVALID_CLUSTER_BOUNDS"
  lacks "沒有 Python traceback" "$out" "Traceback"
  [ -f "$OUT/negative.jsonl" ] && fail "失敗時不該留下輸出檔" \
    || ok "失敗時沒有留下輸出檔"
}

# 先成功寫一次、再用壞輸入對同一路徑跑第二次，應該清掉舊檔案。
test_stale_output_deleted_on_failure() {
  # 第一次成功運行：18 則語料，min=3 max=5 應該通過
  python3 "$MRA_DIR/scripts/cluster-tfidf.py" --input "$IN/nestjs.jsonl" \
    --output "$OUT/stale.jsonl" --min-clusters 3 --max-clusters 5 >/dev/null 2>&1
  local first_size
  first_size="$(wc -l < "$OUT/stale.jsonl" | tr -d ' ')"
  [ "$first_size" -gt 0 ] && ok "第一次成功產出 ${first_size} 行" \
    || fail "第一次運行失敗"

  # 第二次失敗運行：同路徑，但用壞輸入（太少樣本）
  local out rc
  out="$(python3 "$MRA_DIR/scripts/cluster-tfidf.py" --input "$IN/nestjs.jsonl" \
    --output "$OUT/stale.jsonl" --min-clusters 15 --max-clusters 40 2>&1)"; rc=$?
  [ "$rc" -ne 0 ] && ok "第二次運行失敗（退出碼非 0）" \
    || fail "應該失敗但沒有"

  # 檢查舊檔案是否被清掉
  [ -f "$OUT/stale.jsonl" ] && fail "失敗後舊輸出檔仍存在（BUG）" \
    || ok "失敗時清掉了舊輸出檔"
}

test_separates_distinct_topics
test_members_stay_within_topic
test_deterministic
test_respects_cluster_bounds
test_top_terms_present
test_empty_input_fails_loudly
test_too_few_samples_fails_loudly
test_lance_williams_matches_bruteforce_reference
test_null_and_empty_body_fields_do_not_crash
test_identical_tokens_do_not_divide_by_zero
test_zero_idf_document_does_not_divide_by_zero
test_single_record_reports_too_few_samples
test_contradictory_bounds_fail_loudly
test_malformed_jsonl_line_fails_loudly
test_all_stopword_vocab_produces_empty_top_terms_without_crash
test_sample_cap_takes_equidistant_records
test_min_clusters_below_one_fails_loudly
test_stale_output_deleted_on_failure

echo "---"; echo "Passed: $pass"; echo "Failed: $errors"
exit $((errors > 0 ? 1 : 0))
