# 階段三：規則萃取 實作計畫

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 從 17 萬則外部 review 語料萃出兩套規則集（依 spec 的 TF-IDF 分群、依回測 finding 分類），用階段二的基準線比較哪一套的 miss_rate 低。

**Architecture:** 篩選結果先落地成每層一個 JSONL（目前是管線函式、不落地，729M 原始 JSON 每次重算太貴）。兩條萃取路線讀同一份落地語料，各自產出 `agents/review-rules/{tfidf,taxonomy}/*.md`。規則透過注入 persona 的 FOCUS 區塊進到 review，再跑階段二的 `run-backtest.sh` 比較。

**Tech Stack:** bash + jq（與階段一、二一致）、python3 只用於 TF-IDF 與階層式分群（bash 做不了向量運算）

**Spec:** `docs/superpowers/specs/2026-08-14-team-code-review-ruleset-design.md`

**回測基準線:** `docs/superpowers/notes/2026-backtest-baseline.md`
**finding 分類:** `docs/superpowers/notes/2026-backtest-finding-taxonomy.md`

## Global Constraints

- 語料目錄 `${MRA_CORPUS_DIR:-$HOME/.cache/mra-review-corpus}`，原始檔是每 repo 一個目錄、內含 `0001.json` 這種分頁檔，每個檔是一個 JSON 陣列
- 層的定義來自 `lib/corpus-targets.sh`：`corpus_layers()` 印出 `common nestjs rails react vue`，`corpus_layer_of <repo>` 查單一 repo 的層
- 篩選函式來自 `lib/corpus-filter.sh`：`corpus_filter_all <repo> <layer>` 讀 stdin 的 JSON 陣列、寫 stdout
- 新增 `lib/*.sh` 要註冊進 `bin/mra.sh` 的 `MRA_LIBS`，`tests/test_lib_loader.sh` 會驗
- canonical 規則檔格式見 spec 的「canonical 檔案格式」章節，必填 frontmatter：`id`、`layer`、`frameworks`、`severity_default`；必填章節：觸發訊號、判準、嚴重度、反例、出處
- 出處不足三則的規則直接丟棄，並在 log 印出丟了幾條與哪些主題
- 回測比較必須用 `candidates_sha` = `7a8226ee333100a9` 的候選集，兩個容差（5 與 15）都算
- 基準線：A（standard+codex）0.87／0.81，C（personas+claude）0.85／0.69

## 這個 repo 的已知陷阱（都付過代價）

- `awk -v var="$值"` 會處理反斜線跳脫並在含換行時 crash；用 `ENVIRON`
- 無參數的 `mktemp` 在 macOS 忽略 `TMPDIR`；一定帶 template
- `$var` 後面直接接全形字元會讓 bash 報 unbound variable，要寫 `${var}`
- `local x="$(cmd)"` 的 `$?` 恆為 0；要拿退出碼得分兩行寫
- `gh api` 的 `--jq` 不接受 `--arg`
- jq 解析失敗的退出碼是 5，不是 1
- `mv` 的退出碼一定要驗
- jq 的 `gsub(...; ...; "s")` 不會讓 `.` 匹配換行

---

## 檔案結構

| 檔案 | 責任 |
| --- | --- |
| `lib/corpus-materialize.sh` | 把篩選結果落地成每層一個 JSONL，可續跑 |
| `scripts/corpus-materialize.sh` | 上者的 CLI 包裝，印進度與各層筆數 |
| `lib/rule-schema.sh` | canonical 規則檔的解析與驗證 |
| `scripts/rule-validate.sh` | 驗證某個目錄下所有規則檔，CLI |
| `scripts/cluster-tfidf.py` | A 路線：TF-IDF 向量 + 階層式分群，輸出群組指派 |
| `scripts/extract-rules-tfidf.sh` | A 路線：每群派 agent 產一條規則 |
| `scripts/extract-rules-taxonomy.sh` | B 路線：依八類骨架到語料找實例、產規則 |
| `lib/rule-inject.sh` | 把規則注入 persona 的 FOCUS 區塊 |
| `scripts/run-rule-backtest.sh` | 帶規則跑回測，包裝 `run-backtest.sh` |
| `agents/review-rules/tfidf/*.md` | A 路線產出 |
| `agents/review-rules/taxonomy/*.md` | B 路線產出 |

---

### Task 1: 語料落地

篩選目前是管線函式、結果不落地。兩條萃取路線都要反覆讀同一份語料，729M 原始
JSON 每次重算太貴，而且兩條路線必須讀到**完全一樣**的語料，否則比較的是語料差異。

**Files:**
- Create: `lib/corpus-materialize.sh`
- Create: `scripts/corpus-materialize.sh`
- Create: `tests/test_corpus_materialize.sh`
- Modify: `bin/mra.sh`（把新 lib 加進 `MRA_LIBS`）

**Interfaces:**
- Consumes: `corpus_layers()`、`corpus_layer_of <repo>`（`lib/corpus-targets.sh`）、
  `corpus_filter_all <repo> <layer>`（`lib/corpus-filter.sh`）
- Produces: `corpus_materialize_repo <repo> <out_dir>` → 把該 repo 篩選後的意見
  以每行一個 JSON 物件寫進 `<out_dir>/<layer>.jsonl`，回傳寫入筆數到 stdout；
  `corpus_materialize_manifest <out_dir>` → 印出每層筆數與來源 repo 清單

- [ ] **Step 1: 寫失敗的測試**

```bash
# tests/test_corpus_materialize.sh 的核心案例
# 假語料：一個 repo 目錄，兩個分頁檔，含 bot 與短意見
setup_fake_corpus() {
  mkdir -p "$FAKE/nestjs__nest"
  cat > "$FAKE/nestjs__nest/0001.json" <<'JSON'
[
  {"user":{"login":"kamilmysliwiec"},"author_association":"MEMBER",
   "path":"packages/core/a.ts","body":"這段邏輯在 request scope 下會共用實例，要改成 factory","diff_hunk":"@@ -1,3 +1,4 @@\n+x","html_url":"https://github.com/nestjs/nest/pull/1#discussion_r1"},
  {"user":{"login":"coderabbitai[bot]"},"author_association":"NONE",
   "path":"packages/core/b.ts","body":"這是一則夠長的 bot 意見，內容足以通過長度門檻","diff_hunk":"@@ -1,3 +1,4 @@\n+y","html_url":"https://github.com/nestjs/nest/pull/1#discussion_r2"}
]
JSON
}

# 案例 1：bot 被濾掉，真人留下
test_filters_bots() {
  corpus_materialize_repo nestjs/nest "$OUT" >/dev/null
  local n; n="$(wc -l < "$OUT/nestjs.jsonl" | tr -d ' ')"
  eq "只留下非 bot 的一則" "1" "$n"
}

# 案例 2：每行是合法 JSON 物件（不是陣列）
test_output_is_jsonl() {
  corpus_materialize_repo nestjs/nest "$OUT" >/dev/null
  while IFS= read -r line; do
    printf '%s' "$line" | jq -e 'type == "object"' >/dev/null || fail "有一行不是 JSON 物件"
  done < "$OUT/nestjs.jsonl"
  ok "每行都是 JSON 物件"
}

# 案例 3：續跑不重複追加（同一個 repo 跑兩次，筆數不變）
test_idempotent() {
  corpus_materialize_repo nestjs/nest "$OUT" >/dev/null
  local first; first="$(wc -l < "$OUT/nestjs.jsonl" | tr -d ' ')"
  corpus_materialize_repo nestjs/nest "$OUT" >/dev/null
  local second; second="$(wc -l < "$OUT/nestjs.jsonl" | tr -d ' ')"
  eq "跑兩次筆數不變" "$first" "$second"
}

# 案例 4：分頁檔壞掉時用自己的 token 報錯，且不寫出半份檔案
test_broken_page_fails_loudly() {
  printf 'not json' > "$FAKE/nestjs__nest/0002.json"
  local out rc
  out="$(corpus_materialize_repo nestjs/nest "$OUT" 2>&1 >/dev/null)"; rc=$?
  [ "$rc" -ne 0 ] && ok "壞掉的分頁檔退出碼非 0" || fail "應退出非 0"
  has "印出 PAGE_PARSE_FAILED" "$out" "PAGE_PARSE_FAILED"
  has "訊息指名是哪個檔" "$out" "0002.json"
}

# 案例 5：未知 repo（不在 corpus_targets）要報錯，不要默默進 common 層
test_unknown_repo_fails() {
  local out rc
  out="$(corpus_materialize_repo acme/unknown "$OUT" 2>&1 >/dev/null)"; rc=$?
  [ "$rc" -ne 0 ] && ok "未知 repo 退出碼非 0" || fail "應退出非 0"
  has "印出 UNKNOWN_REPO" "$out" "UNKNOWN_REPO"
}
```

- [ ] **Step 2: 跑測試確認失敗**

Run: `bash tests/test_corpus_materialize.sh`
Expected: FAIL，`corpus_materialize_repo: command not found`

- [ ] **Step 3: 實作 `lib/corpus-materialize.sh`**

```bash
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

  # 先全部收集到暫存檔，確認每個分頁都解析成功才 append 到正式檔。
  # 半途失敗就 append 出去的話，續跑會從一份不完整的檔案上再疊一次。
  local tmp
  tmp="$(mktemp "${TMPDIR:-/tmp}/corpus-mat.XXXXXX")" || return 1

  local page total=0
  for page in "$src_dir"/*.json; do
    [ -e "$page" ] || continue
    local filtered
    filtered="$(corpus_filter_all "$repo" "$layer" < "$page" 2>/dev/null)"
    local rc=$?
    if [ $rc -ne 0 ] || ! printf '%s' "$filtered" | jq -e 'type == "array"' >/dev/null 2>&1; then
      printf 'PAGE_PARSE_FAILED\t%s\t%s\n' "$repo" "$page" >&2
      rm -f "$tmp"
      return 1
    fi
    local n
    n="$(printf '%s' "$filtered" | jq 'length')"
    printf '%s' "$filtered" | jq -c --arg r "$repo" --arg l "$layer" \
      '.[] | {repo: $r, layer: $l, path, body, diff_hunk, html_url,
              login: .user.login, association: .author_association}' >> "$tmp" || {
      printf 'PROJECT_FAILED\t%s\t%s\n' "$repo" "$page" >&2
      rm -f "$tmp"
      return 1
    }
    total=$((total + n))
  done

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
```

- [ ] **Step 4: 跑測試確認通過**

Run: `bash tests/test_corpus_materialize.sh`
Expected: PASS，5 個案例全綠

- [ ] **Step 5: 註冊 lib 並確認 loader 測試通過**

在 `bin/mra.sh` 的 `MRA_LIBS` 陣列加入 `corpus-materialize`。

Run: `bash tests/test_lib_loader.sh`
Expected: PASS

- [ ] **Step 6: 寫 CLI 包裝**

```bash
#!/usr/bin/env bash
# scripts/corpus-materialize.sh — 對所有 target repo 跑落地，印進度與各層筆數。
set -uo pipefail
MRA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$MRA_DIR/lib/corpus-targets.sh"
source "$MRA_DIR/lib/corpus-filter.sh"
source "$MRA_DIR/lib/corpus-materialize.sh"

OUT="${MRA_CORPUS_MATERIALIZED:-$HOME/.cache/mra-review-corpus-materialized}"
failed=0
while IFS=$'\t' read -r repo layer; do
  [ -n "$repo" ] || continue
  printf '=== %s（%s 層）\n' "$repo" "$layer"
  if n="$(corpus_materialize_repo "$repo" "$OUT")"; then
    printf '  %s 則\n' "$n"
  else
    printf '  失敗，見上方訊息\n'
    failed=$((failed + 1))
  fi
done < <(corpus_targets)

printf '\n=== 各層筆數\n'
corpus_materialize_manifest "$OUT"
printf '\n失敗 %s 個 repo\n' "$failed"
[ "$failed" -eq 0 ] || exit 1
```

- [ ] **Step 7: 對真實語料跑一次，確認各層筆數合理**

Run: `bash scripts/corpus-materialize.sh`
Expected: 五層都有筆數，總計約 6 萬則（階段一記錄的篩選後語料量），失敗 0 個 repo

- [ ] **Step 8: Commit**

```bash
git add lib/corpus-materialize.sh scripts/corpus-materialize.sh \
        tests/test_corpus_materialize.sh bin/mra.sh
git commit -m "feat(corpus): 篩選結果落地成每層一個 JSONL

兩條萃取路線要讀完全一樣的語料，否則比較出來的差異可能來自語料而不是
萃取方式。原始 JSON 729M，每次重跑篩選太貴。

續跑用 .done 標記檔而不是看輸出檔存不存在：輸出檔是某一層的累積結果，
多個 repo 寫進同一個檔，用它判斷會讓第二個 repo 被跳過。"
```

---

### Task 2: canonical 規則檔 schema 與驗證

兩條路線的產出要通過同一套驗證，否則最後比較的可能是格式差異而不是規則品質。
這個 Task 先做驗證器，兩條萃取路線都拿它當合格線。

**Files:**
- Create: `lib/rule-schema.sh`
- Create: `scripts/rule-validate.sh`
- Create: `tests/test_rule_schema.sh`
- Create: `tests/fixtures/rules/valid-example.md`
- Modify: `bin/mra.sh`（`MRA_LIBS` 加 `rule-schema`）

**Interfaces:**
- Produces:
  - `rule_frontmatter <file>` → 印出 frontmatter 的 YAML 部分（不含 `---` 界線）
  - `rule_field <file> <key>` → 印出單一 frontmatter 欄位的值；缺欄位回空字串、退出碼 1
  - `rule_section <file> <章節標題>` → 印出該 `##` 章節的內容
  - `rule_validate <file>` → 合格回 0；不合格印出每個問題到 stderr 並回 1
  - `rule_source_count <file>` → 印出「出處」章節裡的 URL 數量

- [ ] **Step 1: 寫合格的 fixture**

```markdown
---
id: nestjs-request-scope-leak
layer: nestjs
frameworks: ["@nestjs/core@>=9"]
severity_default: HIGH
---
## 觸發訊號
diff 裡出現 `@Injectable({ scope: Scope.REQUEST })`，或 request-scoped provider
被注入進 singleton service。

## 判準
request-scoped provider 被 singleton 注入時，Nest 會把整條依賴鏈提升成
request scope，每個請求重建一次。原本預期只建一次的物件（連線池、快取）
會跟著重建。

## 嚴重度
CRITICAL：被提升的鏈上有連線池或外部資源 handle
HIGH：被提升的鏈上有具狀態的 service
MEDIUM：只影響無狀態的 helper

## 反例（不該報）
provider 本來就宣告成 request scope 且鏈上全部都是 request scope，
那是刻意的設計，不要報。

## 出處
- https://github.com/nestjs/nest/pull/1001#discussion_r100001
- https://github.com/nestjs/nest/pull/1002#discussion_r100002
- https://github.com/nestjs/nest/pull/1003#discussion_r100003
```

- [ ] **Step 2: 寫失敗的測試**

```bash
# tests/test_rule_schema.sh 的核心案例

test_valid_fixture_passes() {
  rule_validate "$FIX/valid-example.md" 2>"$TMP/err" && ok "合格 fixture 通過" \
    || fail "合格 fixture 應該通過：$(cat "$TMP/err")"
}

test_missing_frontmatter_field() {
  sed '/^severity_default:/d' "$FIX/valid-example.md" > "$TMP/no-sev.md"
  local out; out="$(rule_validate "$TMP/no-sev.md" 2>&1)"
  [ $? -ne 0 ] && ok "缺 severity_default 不通過" || fail "應該不通過"
  has "訊息指名缺哪個欄位" "$out" "severity_default"
}

test_missing_section() {
  # 砍掉「反例」整段
  awk '/^## 反例/{skip=1} /^## 出處/{skip=0} !skip' "$FIX/valid-example.md" > "$TMP/no-counter.md"
  local out; out="$(rule_validate "$TMP/no-counter.md" 2>&1)"
  [ $? -ne 0 ] && ok "缺反例章節不通過" || fail "應該不通過"
  has "訊息指名缺哪個章節" "$out" "反例"
}

test_source_count_below_three() {
  # 只留兩則出處
  sed '/discussion_r100003/d' "$FIX/valid-example.md" > "$TMP/two-src.md"
  local out; out="$(rule_validate "$TMP/two-src.md" 2>&1)"
  [ $? -ne 0 ] && ok "出處只有兩則不通過" || fail "應該不通過"
  has "訊息說出處不足" "$out" "出處"
  eq "rule_source_count 算出 2" "2" "$(rule_source_count "$TMP/two-src.md")"
}

test_severity_default_must_be_known() {
  sed 's/^severity_default: HIGH/severity_default: URGENT/' "$FIX/valid-example.md" > "$TMP/bad-sev.md"
  local out; out="$(rule_validate "$TMP/bad-sev.md" 2>&1)"
  [ $? -ne 0 ] && ok "不認得的 severity 不通過" || fail "應該不通過"
  has "訊息指名不合法的值" "$out" "URGENT"
}

test_id_must_match_filename() {
  cp "$FIX/valid-example.md" "$TMP/wrong-name.md"
  local out; out="$(rule_validate "$TMP/wrong-name.md" 2>&1)"
  [ $? -ne 0 ] && ok "id 與檔名不符不通過" || fail "應該不通過"
  has "訊息說明 id 與檔名要一致" "$out" "wrong-name"
}

test_layer_must_be_known() {
  sed 's/^layer: nestjs/layer: golang/' "$FIX/valid-example.md" > "$TMP/bad-layer.md"
  local out; out="$(rule_validate "$TMP/bad-layer.md" 2>&1)"
  [ $? -ne 0 ] && ok "不認得的 layer 不通過" || fail "應該不通過"
  has "訊息列出合法的 layer" "$out" "nestjs"
}

test_section_extraction() {
  local body; body="$(rule_section "$FIX/valid-example.md" "判準")"
  has "判準章節抓得到內容" "$body" "request-scoped provider"
  lacks "判準章節不含下一節的內容" "$body" "CRITICAL："
}

# 每個問題各報一次，不要遇到第一個就中止 —— 萃取階段一次會產幾十個檔，
# 一次看到全部問題比修一個跑一次快得多。
test_reports_all_problems_at_once() {
  sed -e '/^severity_default:/d' -e '/discussion_r100003/d' \
    "$FIX/valid-example.md" > "$TMP/two-problems.md"
  local out; out="$(rule_validate "$TMP/two-problems.md" 2>&1)"
  has "同時報 severity_default" "$out" "severity_default"
  has "同時報出處不足" "$out" "出處"
}
```

- [ ] **Step 3: 跑測試確認失敗**

Run: `bash tests/test_rule_schema.sh`
Expected: FAIL，`rule_validate: command not found`

- [ ] **Step 4: 實作 `lib/rule-schema.sh`**

```bash
#!/usr/bin/env bash
# canonical 規則檔的解析與驗證。兩條萃取路線的產出都要通過這裡，否則最後
# 比較的可能是格式差異而不是規則品質。
#
# 不用 YAML 解析器：frontmatter 只有四個純量欄位，用 awk 抓比拉一個相依
# 進來划算。frameworks 是陣列但只當字串傳遞，不需要解析內容。
#
# 驗證一次report 所有問題，不是遇到第一個就 return：萃取階段一次產幾十個檔，
# 一次看到全部問題比修一個跑一次快得多。

RULE_VALID_SEVERITIES="CRITICAL HIGH MEDIUM LOW"
RULE_REQUIRED_FIELDS="id layer frameworks severity_default"
RULE_REQUIRED_SECTIONS="觸發訊號 判準 嚴重度 反例 出處"
RULE_MIN_SOURCES=3

rule_frontmatter() {
  local f="$1"
  awk 'NR==1 && $0 != "---" { exit 1 }
       NR>1 && $0 == "---" { exit 0 }
       NR>1 { print }' "$f"
}

rule_field() {
  local f="$1" key="$2" val
  val="$(rule_frontmatter "$f" | RULE_KEY="$key" awk -F': *' \
    '$1 == ENVIRON["RULE_KEY"] { sub(/^[^:]*: */, ""); print; found=1 } END { exit !found }')"
  local rc=$?
  printf '%s' "$val"
  return $rc
}

rule_section() {
  local f="$1" title="$2"
  RULE_TITLE="## $title" awk '
    $0 == ENVIRON["RULE_TITLE"] { inside=1; next }
    inside && /^## / { exit }
    inside { print }' "$f"
}

rule_source_count() {
  rule_section "$1" 出處 | grep -cE 'https?://' || true
}

rule_validate() {
  local f="$1" problems=0
  [ -f "$f" ] || { printf 'RULE_FILE_MISSING\t%s\n' "$f" >&2; return 1; }

  local base; base="$(basename "$f" .md)"

  local key
  for key in $RULE_REQUIRED_FIELDS; do
    if ! rule_field "$f" "$key" >/dev/null; then
      printf 'RULE_FIELD_MISSING\t%s\t%s\n' "$f" "$key" >&2
      problems=$((problems + 1))
    fi
  done

  local id; id="$(rule_field "$f" id 2>/dev/null)"
  if [ -n "$id" ] && [ "$id" != "$base" ]; then
    printf 'RULE_ID_MISMATCH\t%s\tid=%s 但檔名是 %s，兩者必須一致\n' "$f" "$id" "$base" >&2
    problems=$((problems + 1))
  fi

  local layer; layer="$(rule_field "$f" layer 2>/dev/null)"
  if [ -n "$layer" ] && ! printf '%s\n' $(corpus_layers) | grep -qx "$layer"; then
    printf 'RULE_LAYER_INVALID\t%s\t%s 不在合法清單：%s\n' \
      "$f" "$layer" "$(corpus_layers | tr '\n' ' ')" >&2
    problems=$((problems + 1))
  fi

  local sev; sev="$(rule_field "$f" severity_default 2>/dev/null)"
  if [ -n "$sev" ] && ! printf '%s\n' $RULE_VALID_SEVERITIES | grep -qx "$sev"; then
    printf 'RULE_SEVERITY_INVALID\t%s\t%s 不在合法清單：%s\n' \
      "$f" "$sev" "$RULE_VALID_SEVERITIES" >&2
    problems=$((problems + 1))
  fi

  local section
  for section in $RULE_REQUIRED_SECTIONS; do
    if [ -z "$(rule_section "$f" "$section" | tr -d '[:space:]')" ]; then
      printf 'RULE_SECTION_MISSING\t%s\t%s\n' "$f" "$section" >&2
      problems=$((problems + 1))
    fi
  done

  local n; n="$(rule_source_count "$f")"
  if [ "$n" -lt "$RULE_MIN_SOURCES" ]; then
    printf 'RULE_SOURCES_TOO_FEW\t%s\t出處只有 %s 則，至少要 %s 則\n' \
      "$f" "$n" "$RULE_MIN_SOURCES" >&2
    problems=$((problems + 1))
  fi

  [ "$problems" -eq 0 ]
}
```

- [ ] **Step 5: 跑測試確認通過**

Run: `bash tests/test_rule_schema.sh`
Expected: PASS，9 個案例全綠

- [ ] **Step 6: 寫 CLI 並註冊 lib**

```bash
#!/usr/bin/env bash
# scripts/rule-validate.sh <目錄> — 驗證目錄下所有 .md 規則檔。
set -uo pipefail
MRA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$MRA_DIR/lib/corpus-targets.sh"
source "$MRA_DIR/lib/rule-schema.sh"

DIR="${1:-}"
[ -d "$DIR" ] || { echo "用法：rule-validate.sh <規則目錄>" >&2; exit 1; }

pass=0; fail=0
for f in "$DIR"/*.md; do
  [ -e "$f" ] || continue
  if rule_validate "$f"; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
  fi
done
printf '合格 %s、不合格 %s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
```

在 `bin/mra.sh` 的 `MRA_LIBS` 加入 `rule-schema`。

Run: `bash tests/test_lib_loader.sh`
Expected: PASS

- [ ] **Step 7: Commit**

```bash
git add lib/rule-schema.sh scripts/rule-validate.sh tests/test_rule_schema.sh \
        tests/fixtures/rules/valid-example.md bin/mra.sh
git commit -m "feat(rules): canonical 規則檔的 schema 與驗證

兩條萃取路線的產出都要通過同一套驗證，否則最後比較的可能是格式差異
而不是規則品質。

驗證一次報所有問題而不是遇到第一個就 return：萃取階段一次產幾十個檔，
一次看到全部問題比修一個跑一次快得多。"
```

---

### Task 3: A 路線 — TF-IDF 分層分群

spec 的原始設計。層內用 `diff_hunk` 與 `body` 的 token 做 TF-IDF 向量，跑階層式
分群，切在 15 到 40 群之間。群數上下限是為了避免一群包山包海或碎成單則。

用 python3 而不是 bash：向量運算與階層式分群 bash 做不了。只用標準庫，不拉
scikit-learn —— TF-IDF 與 average-linkage 自己寫約 120 行，比要求安裝相依划算，
而且分群結果要能重現，相依版本變動會讓結果漂移。

**Files:**
- Create: `scripts/cluster-tfidf.py`
- Create: `tests/test_cluster_tfidf.sh`

**Interfaces:**
- Consumes: `<materialized>/<layer>.jsonl`（Task 1 的產出）
- Produces: `<out>/<layer>-clusters.jsonl`，每行
  `{"cluster": <int>, "n": <int>, "top_terms": [...], "members": [{"html_url":..., "path":..., "body":...}]}`

- [ ] **Step 1: 寫失敗的測試**

```bash
# tests/test_cluster_tfidf.sh
# 假語料：三組明顯不同主題的意見，每組 6 則，共 18 則。
# 分群應該把它們分開，而不是全部混成一群。

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

test_separates_distinct_topics() {
  python3 "$MRA_DIR/scripts/cluster-tfidf.py" --input "$IN/nestjs.jsonl" \
    --output "$OUT/nestjs-clusters.jsonl" --min-clusters 3 --max-clusters 5
  local n; n="$(wc -l < "$OUT/nestjs-clusters.jsonl" | tr -d ' ')"
  [ "$n" -ge 3 ] && ok "至少分成 3 群（實際 $n）" || fail "只分成 $n 群"
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
  [ "$n" -ge 2 ] && [ "$n" -le 4 ] && ok "群數在 2-4 之間（實際 $n）" \
    || fail "群數 $n 超出 2-4"
}

test_top_terms_present() {
  local terms
  terms="$(jq -r '.top_terms | join(",")' "$OUT/nestjs-clusters.jsonl" | head -1)"
  [ -n "$terms" ] && ok "有 top_terms（$terms）" || fail "top_terms 是空的"
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
```

- [ ] **Step 2: 跑測試確認失敗**

Run: `bash tests/test_cluster_tfidf.sh`
Expected: FAIL，`can't open file 'scripts/cluster-tfidf.py'`

- [ ] **Step 3: 實作 `scripts/cluster-tfidf.py`**

```python
#!/usr/bin/env python3
"""TF-IDF + average-linkage 階層式分群。

只用標準庫，不拉 scikit-learn：TF-IDF 與 average-linkage 自己寫約 120 行，
比要求安裝相依划算，而且分群結果要能重現 —— 相依版本變動會讓結果漂移，
而重現性是這條路線能不能跟 B 路線公平比較的前提。

決定性：token 排序固定、合併時 tie 用 (i, j) 的字典序決定，不依賴 dict
的插入順序或浮點數比較的偶然結果。
"""
import argparse, json, math, re, sys
from collections import Counter

TOKEN = re.compile(r"[A-Za-z_][A-Za-z0-9_]{2,}")
STOP = {"the","this","that","for","are","and","not","you","但是","這個","可以"}


def tokenize(text):
    return [t.lower() for t in TOKEN.findall(text or "") if t.lower() not in STOP]


def load(path):
    rows = []
    with open(path, encoding="utf-8") as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            try:
                rows.append(json.loads(line))
            except json.JSONDecodeError as exc:
                print(f"LINE_PARSE_FAILED\t{path}\t{exc}", file=sys.stderr)
                sys.exit(1)
    return rows


def tfidf(rows):
    docs = [tokenize((r.get("body") or "") + " " + (r.get("diff_hunk") or "")) for r in rows]
    df = Counter()
    for d in docs:
        df.update(set(d))
    vocab = sorted(df)                      # 排序固定 → 向量維度順序可重現
    idx = {t: i for i, t in enumerate(vocab)}
    n = len(docs)
    vecs = []
    for d in docs:
        tf = Counter(d)
        v = {}
        for t, c in tf.items():
            v[idx[t]] = (c / len(d)) * math.log(n / (1 + df[t]))
        norm = math.sqrt(sum(x * x for x in v.values())) or 1.0
        vecs.append({k: x / norm for k, x in v.items()})
    return vecs, vocab


def cosine(a, b):
    if len(a) > len(b):
        a, b = b, a
    return sum(x * b.get(k, 0.0) for k, x in a.items())


def cluster(vecs, target):
    """average-linkage，合併到剩 target 群。

    tie 用 (i, j) 決定而不是「先遇到的」：浮點數相等在不同平台可能有不同的
    遍歷順序，那會讓同樣的輸入在不同機器上分出不同的群。
    """
    groups = [[i] for i in range(len(vecs))]
    sim = {}
    for i in range(len(vecs)):
        for j in range(i + 1, len(vecs)):
            sim[(i, j)] = cosine(vecs[i], vecs[j])

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


def top_terms(group, vecs, vocab, k=6):
    agg = Counter()
    for i in group:
        for idx, w in vecs[i].items():
            agg[idx] += w
    return [vocab[i] for i, _ in agg.most_common(k)]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--input", required=True)
    ap.add_argument("--output", required=True)
    ap.add_argument("--min-clusters", type=int, default=15)
    ap.add_argument("--max-clusters", type=int, default=40)
    args = ap.parse_args()

    rows = load(args.input)
    if not rows:
        print(f"EMPTY_INPUT\t{args.input}\t沒有任何可分群的意見", file=sys.stderr)
        sys.exit(1)
    # 每群至少要有 3 則才寫得出有出處的規則（spec：出處不足三則直接丟棄）。
    # 樣本數撐不起下限群數時，硬切只會產出一堆註定被丟棄的群。
    if len(rows) < args.min_clusters * 3:
        print(f"TOO_FEW_SAMPLES\t{args.input}\t{len(rows)} 則撐不起 "
              f"{args.min_clusters} 群（每群至少 3 則）", file=sys.stderr)
        sys.exit(1)

    vecs, vocab = tfidf(rows)
    target = max(args.min_clusters, min(args.max_clusters, len(rows) // 20))
    target = min(target, len(rows))
    groups = cluster(vecs, target)

    with open(args.output, "w", encoding="utf-8") as fh:
        for cid, g in enumerate(groups):
            fh.write(json.dumps({
                "cluster": cid,
                "n": len(g),
                "top_terms": top_terms(g, vecs, vocab),
                "members": [{
                    "html_url": rows[i].get("html_url"),
                    "path": rows[i].get("path"),
                    "body": rows[i].get("body"),
                    "diff_hunk": rows[i].get("diff_hunk"),
                } for i in g],
            }, ensure_ascii=False) + "\n")
    print(f"{args.input}\t{len(rows)} 則 → {len(groups)} 群")


if __name__ == "__main__":
    main()
```

- [ ] **Step 4: 跑測試確認通過**

Run: `bash tests/test_cluster_tfidf.sh`
Expected: PASS，7 個案例全綠

- [ ] **Step 5: 對真實語料跑一次**

```bash
OUT="${MRA_CORPUS_MATERIALIZED:-$HOME/.cache/mra-review-corpus-materialized}"
for layer in common nestjs rails react vue; do
  python3 scripts/cluster-tfidf.py --input "$OUT/${layer}.jsonl" \
    --output "$OUT/${layer}-clusters.jsonl" || echo "跳過 ${layer}"
done
```

Expected: 每層印出「N 則 → M 群」，M 在 15 到 40 之間。
語料量小的層可能觸發 `TOO_FEW_SAMPLES`，那是正常的，記下來即可。

**注意執行時間**：average-linkage 是 O(n³)，六萬則會跑不完。實測後若某層超過
5 分鐘，先對該層抽樣（每層上限 2000 則，用 `shuf` 但固定 seed 保持可重現）
再分群，並在 log 印出抽樣前後的筆數。抽樣這件事要寫進基準線比較的執行條件。

- [ ] **Step 6: Commit**

```bash
git add scripts/cluster-tfidf.py tests/test_cluster_tfidf.sh
git commit -m "feat(rules): A 路線的 TF-IDF 分層分群

只用標準庫不拉 scikit-learn：分群結果要能重現，相依版本變動會讓結果漂移，
而重現性是這條路線能跟 B 路線公平比較的前提。

合併時 tie 用 (i, j) 字典序決定而不是「先遇到的」：浮點數相等在不同平台
可能有不同遍歷順序，那會讓同樣的輸入在不同機器上分出不同的群。"
```

---

### Task 4: A 路線 — 依群萃取規則

每個主題群交給 agent 產出一條 canonical 規則。出處不足三則的群直接丟棄，
並在 log 印出丟了幾條與哪些主題。

**Files:**
- Create: `scripts/extract-rules-tfidf.sh`
- Create: `tests/test_extract_rules_tfidf.sh`
- Create（產出）: `agents/review-rules/tfidf/*.md`

**Interfaces:**
- Consumes: `<materialized>/<layer>-clusters.jsonl`（Task 3）、`rule_validate`（Task 2）
- Produces: `agents/review-rules/tfidf/<id>.md`，以及 `agents/review-rules/tfidf/_dropped.tsv`
  （被丟棄的群：cluster id、筆數、top_terms、丟棄原因）

- [ ] **Step 1: 寫失敗的測試**

```bash
# tests/test_extract_rules_tfidf.sh
# agent 呼叫用 stub：把 MRA_RULE_AGENT_CMD 指到一個吐固定規則檔的腳本。
# 這裡要驗的是流程（丟棄規則、驗證、檔名），不是 agent 產出的品質。

write_agent_stub() {
  cat > "$STUB/agent" <<'SH'
#!/usr/bin/env bash
# 讀 stdin 的群組 JSON，吐一份合格的規則檔
cid="$(jq -r '.cluster')"
cat <<MD
---
id: nestjs-stub-rule-${cid}
layer: nestjs
frameworks: ["@nestjs/core@>=9"]
severity_default: HIGH
---
## 觸發訊號
stub 觸發條件

## 判準
stub 判準內容

## 嚴重度
CRITICAL：stub
HIGH：stub
MEDIUM：stub

## 反例（不該報）
stub 反例

## 出處
$(jq -r '.members[] | "- " + .html_url')
MD
SH
  chmod +x "$STUB/agent"
}

test_drops_clusters_with_too_few_sources() {
  # 一群 5 則、一群 2 則
  printf '%s\n' \
    '{"cluster":0,"n":5,"top_terms":["scope"],"members":[{"html_url":"https://x/1"},{"html_url":"https://x/2"},{"html_url":"https://x/3"},{"html_url":"https://x/4"},{"html_url":"https://x/5"}]}' \
    '{"cluster":1,"n":2,"top_terms":["test"],"members":[{"html_url":"https://x/6"},{"html_url":"https://x/7"}]}' \
    > "$IN/nestjs-clusters.jsonl"
  MRA_RULE_AGENT_CMD="$STUB/agent" bash "$MRA_DIR/scripts/extract-rules-tfidf.sh" \
    --clusters "$IN/nestjs-clusters.jsonl" --out "$OUT" >/dev/null 2>&1
  eq "只產出 1 個規則檔" "1" "$(ls "$OUT"/*.md 2>/dev/null | wc -l | tr -d ' ')"
  has "被丟棄的群有記錄" "$(cat "$OUT/_dropped.tsv")" "1"
}

test_dropped_log_names_the_topic() {
  has "丟棄記錄含 top_terms" "$(cat "$OUT/_dropped.tsv")" "test"
}

test_output_passes_validation() {
  for f in "$OUT"/*.md; do
    rule_validate "$f" || fail "產出的規則檔沒通過驗證：$f"
  done
  ok "所有產出都通過 rule_validate"
}

test_invalid_agent_output_is_rejected() {
  cat > "$STUB/bad-agent" <<'SH'
#!/usr/bin/env bash
echo "這不是規則檔，只是一段散文"
SH
  chmod +x "$STUB/bad-agent"
  local out
  out="$(MRA_RULE_AGENT_CMD="$STUB/bad-agent" bash "$MRA_DIR/scripts/extract-rules-tfidf.sh" \
    --clusters "$IN/nestjs-clusters.jsonl" --out "$OUT2" 2>&1)"
  has "印出 RULE_REJECTED" "$out" "RULE_REJECTED"
  eq "不合格的產出不落地" "0" "$(ls "$OUT2"/*.md 2>/dev/null | wc -l | tr -d ' ')"
}

test_summary_counts() {
  local out
  out="$(MRA_RULE_AGENT_CMD="$STUB/agent" bash "$MRA_DIR/scripts/extract-rules-tfidf.sh" \
    --clusters "$IN/nestjs-clusters.jsonl" --out "$OUT3" 2>&1)"
  has "印出產出數" "$out" "產出 1"
  has "印出丟棄數" "$out" "丟棄 1"
}
```

- [ ] **Step 2: 跑測試確認失敗**

Run: `bash tests/test_extract_rules_tfidf.sh`
Expected: FAIL，找不到 `scripts/extract-rules-tfidf.sh`

- [ ] **Step 3: 實作 `scripts/extract-rules-tfidf.sh`**

```bash
#!/usr/bin/env bash
# A 路線：每個主題群交給 agent 產出一條 canonical 規則。
#
# 出處不足三則的群在「呼叫 agent 之前」就丟棄，不是產出後才驗：那些群註定
# 寫不出合格規則，先丟可以省掉幾十次模型呼叫。spec 的原話是「樣本太少寫出來
# 的規則是幻覺」。
#
# agent 產出一律先過 rule_validate 才落地。不合格的印出 RULE_REJECTED 與
# 完整的驗證訊息，並把原始產出留在 <out>/_rejected/<cluster>.md 供診斷 ——
# 直接丟掉的話沒辦法判斷是 prompt 的問題還是模型的問題。
set -uo pipefail
MRA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$MRA_DIR/lib/corpus-targets.sh"
source "$MRA_DIR/lib/rule-schema.sh"

CLUSTERS=""; OUT=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --clusters) CLUSTERS="$2"; shift 2 ;;
    --out) OUT="$2"; shift 2 ;;
    *) echo "用法：extract-rules-tfidf.sh --clusters <檔> --out <目錄>" >&2; exit 1 ;;
  esac
done
[ -s "$CLUSTERS" ] || { echo "CLUSTERS_MISSING：${CLUSTERS}" >&2; exit 1; }
mkdir -p "$OUT" "$OUT/_rejected" || exit 1
: > "$OUT/_dropped.tsv"

AGENT="${MRA_RULE_AGENT_CMD:-}"
[ -n "$AGENT" ] || { echo "MRA_RULE_AGENT_CMD 未設定" >&2; exit 1; }

produced=0; dropped=0; rejected=0
while IFS= read -r cluster; do
  [ -n "$cluster" ] || continue
  cid="$(printf '%s' "$cluster" | jq -r '.cluster')"
  nsrc="$(printf '%s' "$cluster" | jq -r '[.members[].html_url] | unique | length')"
  terms="$(printf '%s' "$cluster" | jq -r '.top_terms | join(",")')"

  if [ "$nsrc" -lt 3 ]; then
    printf '%s\t%s\t%s\t出處只有 %s 則\n' "$cid" \
      "$(printf '%s' "$cluster" | jq -r '.n')" "$terms" "$nsrc" >> "$OUT/_dropped.tsv"
    dropped=$((dropped + 1))
    continue
  fi

  raw="$(printf '%s' "$cluster" | "$AGENT")" || {
    printf 'AGENT_FAILED\tcluster=%s\n' "$cid" >&2
    rejected=$((rejected + 1)); continue
  }

  # id 從產出的 frontmatter 讀，檔名跟著它 —— rule_validate 會驗兩者一致，
  # 所以先寫到暫存檔、讀出 id、再改名到正式位置。
  tmp="$(mktemp "${TMPDIR:-/tmp}/rule.XXXXXX")" || exit 1
  printf '%s\n' "$raw" > "$tmp"
  id="$(rule_field "$tmp" id 2>/dev/null)"
  if [ -z "$id" ]; then
    cp "$tmp" "$OUT/_rejected/${cid}.md"
    printf 'RULE_REJECTED\tcluster=%s\t產出沒有 id 欄位，原始輸出留在 _rejected/%s.md\n' \
      "$cid" "$cid" >&2
    rm -f "$tmp"; rejected=$((rejected + 1)); continue
  fi

  dest="$OUT/${id}.md"
  mv "$tmp" "$dest" || { echo "MOVE_FAILED：${dest}" >&2; rm -f "$tmp"; exit 1; }
  if ! rule_validate "$dest"; then
    mv "$dest" "$OUT/_rejected/${cid}.md"
    printf 'RULE_REJECTED\tcluster=%s\t沒通過驗證，原始輸出留在 _rejected/%s.md\n' \
      "$cid" "$cid" >&2
    rejected=$((rejected + 1)); continue
  fi
  produced=$((produced + 1))
done < "$CLUSTERS"

printf '產出 %s、丟棄 %s（出處不足）、退回 %s（驗證不過）\n' \
  "$produced" "$dropped" "$rejected"
```

- [ ] **Step 4: 跑測試確認通過**

Run: `bash tests/test_extract_rules_tfidf.sh`
Expected: PASS，5 個案例全綠

- [ ] **Step 5: 寫真正的 agent 呼叫腳本**

```bash
#!/usr/bin/env bash
# scripts/rule-agent.sh — 讀 stdin 的群組 JSON，呼叫 claude 產出 canonical 規則。
# 兩條萃取路線共用這支，差別只在餵進來的 JSON 形狀與 prompt 前綴。
set -uo pipefail
MRA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
input="$(cat)"
prefix="${MRA_RULE_PROMPT_PREFIX:-這是一組主題相近的 code review 意見。}"

prompt="${prefix}

請產出一條 canonical 規則，格式如下（frontmatter 與五個章節都必填）：

---
id: <層>-<用連字號的簡短英文描述>
layer: <common|nestjs|rails|react|vue 其中之一>
frameworks: [\"<套件@版本範圍>\"]
severity_default: <CRITICAL|HIGH|MEDIUM|LOW>
---
## 觸發訊號
（diff 裡出現什麼樣的東西時要套用這條規則。要具體到可以比對，不要寫「當有問題時」。）

## 判準
（為什麼那是問題。寫資深 reviewer 實際的理由，不要寫教科書定義。）

## 嚴重度
CRITICAL：（什麼情況）
HIGH：（什麼情況）
MEDIUM：（什麼情況）

## 反例（不該報）
（什麼情況看起來像但不該報。這一節不能空著 —— 沒有反例的規則會製造雜訊。）

## 出處
（下面每一則意見的 html_url，一行一個，前面加 \"- \"）

意見：
${input}"

MRA_REVIEW_EMIT_JSON= claude -p "$prompt" \
  --model "${MRA_RULE_AGENT_MODEL:-sonnet}" \
  --max-turns "${MRA_RULE_AGENT_MAX_TURNS:-4}" \
  --disallowedTools "Write,Edit,NotebookEdit" 2>/dev/null
```

- [ ] **Step 6: 對真實分群跑一次**

```bash
OUT="${MRA_CORPUS_MATERIALIZED:-$HOME/.cache/mra-review-corpus-materialized}"
for layer in common nestjs rails react vue; do
  [ -s "$OUT/${layer}-clusters.jsonl" ] || continue
  MRA_RULE_AGENT_CMD="$PWD/scripts/rule-agent.sh" \
    bash scripts/extract-rules-tfidf.sh \
      --clusters "$OUT/${layer}-clusters.jsonl" \
      --out agents/review-rules/tfidf
done
bash scripts/rule-validate.sh agents/review-rules/tfidf
```

Expected: 每層印出「產出 N、丟棄 M、退回 K」，最後驗證全部合格。
退回數若超過產出數的三成，先看 `_rejected/` 裡的原始輸出再決定是調 prompt 還是換模型。

- [ ] **Step 7: Commit**

```bash
git add scripts/extract-rules-tfidf.sh scripts/rule-agent.sh \
        tests/test_extract_rules_tfidf.sh agents/review-rules/tfidf
git commit -m "feat(rules): A 路線依 TF-IDF 群萃取規則

出處不足三則的群在呼叫 agent 之前就丟棄，不是產出後才驗：那些群註定寫不出
合格規則，先丟省掉幾十次模型呼叫。

不合格的產出留在 _rejected/ 而不是直接丟掉：沒有原始輸出就沒辦法判斷是
prompt 的問題還是模型的問題。"
```

---

### Task 5: B 路線 — 依 finding 分類萃取規則

骨架來自回測資料（`2026-backtest-finding-taxonomy.md` 的八類），語料的角色是
提供每一類的判準與反例。與 A 路線的差別：A 是先分群再看群裡有什麼，B 是先知道
要找什麼再去語料裡撈。

八類與各自的漏抓數（A 那輪 47 條）：缺席 10、狀態範圍 8、框架語意 7、
狀態遺漏 6、測試品質 5、快取一致性 4、錯誤守衛 3、領域與邏輯 4。

**Files:**
- Create: `lib/taxonomy-classes.sh`（八類的定義與檢索關鍵詞）
- Create: `scripts/extract-rules-taxonomy.sh`
- Create: `tests/test_extract_rules_taxonomy.sh`
- Create（產出）: `agents/review-rules/taxonomy/*.md`
- Modify: `bin/mra.sh`（`MRA_LIBS` 加 `taxonomy-classes`）

**Interfaces:**
- Consumes: `<materialized>/<layer>.jsonl`（Task 1）、`rule_validate`（Task 2）
- Produces:
  - `taxonomy_classes()` → 一行一類，`<class_id>\t<中文名>\t<檢索關鍵詞用 | 分隔>`
  - `taxonomy_search <class_id> <jsonl> <上限>` → 從語料撈出該類的候選意見，JSONL

- [ ] **Step 1: 寫 `lib/taxonomy-classes.sh`**

```bash
#!/usr/bin/env bash
# 八類的定義。class_id 用英文（會變成規則檔名的一部分），中文名用於 log。
#
# 檢索關鍵詞是「reviewer 講這一類問題時實際會用的字」，不是分類名稱的翻譯。
# 例如「缺席」那一類，reviewer 不會說 "absence"，會說 "should also"、
# "missing"、"other routes have"、"consistent with"。關鍵詞取自 A 那輪 30 條
# comment 與語料抽樣的實際用字。
#
# 一則意見可能同時命中多類，不去重 —— 同一則意見支持兩條規則是正常的，
# 強制歸一類會丟掉資訊。

taxonomy_classes() {
  cat <<'CLASSES'
missing-convention	缺席：應該有而沒有	should also|missing|other .* (have|has)|consistent with|same pattern|elsewhere we|forgot to add|needs? a? ?(guard|check|test)
shared-state-scope	狀態範圍：共用了不該共用的狀態	shared (state|instance)|per-.* key|not scoped|same reference|singleton|global
framework-semantics	框架語意	actually returns|in (rails|react|vue|nest) this|behaves differently|is truthy|will be called twice|strict ?mode
missing-state-case	狀態遺漏：三態當兩態	loading|error state|only handles|what if .* fails|third case|pending
test-quality	測試品質	test (does not|doesn't) (fail|verify)|mock(s|ed)? (the )?(entire|whole)|assertion|would still pass|not actually test
cache-invalidation	快取一致性	invalidate|stale|cache key|refetch|out of date
error-guard-condition	錯誤守衛：有檢查但條件錯	only (runs|checks) when|can be bypassed|condition is|guard (does not|doesn't)|skips when
domain-logic	領域與邏輯	off by one|rounding|timezone|currency|precision|edge case
CLASSES
}

taxonomy_search() {
  local class_id="$1" jsonl="$2" limit="${3:-40}"
  local pattern
  pattern="$(taxonomy_classes | TAX_ID="$class_id" awk -F'\t' \
    '$1 == ENVIRON["TAX_ID"] { print $3; found=1 } END { exit !found }')" || {
    printf 'UNKNOWN_CLASS\t%s\n' "$class_id" >&2
    return 1
  }
  [ -s "$jsonl" ] || { printf 'CORPUS_MISSING\t%s\n' "$jsonl" >&2; return 1; }

  # 用 jq 的 test() 做大小寫不敏感比對。body 為 null 的行已在 Task 1 濾掉，
  # 但仍加 // "" 防禦：語料是外部資料，不要假設。
  jq -c --arg p "$pattern" \
    'select((.body // "") | test($p; "i"))' "$jsonl" | head -"$limit"
}
```

- [ ] **Step 2: 寫失敗的測試**

```bash
# tests/test_extract_rules_taxonomy.sh

test_all_eight_classes_defined() {
  eq "定義了 8 類" "8" "$(taxonomy_classes | wc -l | tr -d ' ')"
}

test_class_ids_unique() {
  eq "class_id 沒有重複" \
    "$(taxonomy_classes | cut -f1 | wc -l | tr -d ' ')" \
    "$(taxonomy_classes | cut -f1 | sort -u | wc -l | tr -d ' ')"
}

test_search_finds_matching_comment() {
  printf '%s\n' \
    '{"body":"The other routes have a beforeLoad guard, this one is missing it","html_url":"https://x/1","path":"a.tsx"}' \
    '{"body":"nit: rename this variable","html_url":"https://x/2","path":"b.tsx"}' \
    > "$IN/react.jsonl"
  local hits; hits="$(taxonomy_search missing-convention "$IN/react.jsonl" 10 | wc -l | tr -d ' ')"
  eq "撈到 1 則" "1" "$hits"
}

test_search_is_case_insensitive() {
  printf '{"body":"MISSING a null check here","html_url":"https://x/3","path":"c.tsx"}\n' > "$IN/r2.jsonl"
  eq "大小寫不敏感" "1" "$(taxonomy_search missing-convention "$IN/r2.jsonl" 10 | wc -l | tr -d ' ')"
}

test_unknown_class_fails_loudly() {
  local out rc
  out="$(taxonomy_search no-such-class "$IN/react.jsonl" 10 2>&1)"; rc=$?
  [ "$rc" -ne 0 ] && ok "未知類別退出碼非 0" || fail "應退出非 0"
  has "印出 UNKNOWN_CLASS" "$out" "UNKNOWN_CLASS"
}

test_respects_limit() {
  : > "$IN/many.jsonl"
  for i in $(seq 1 20); do
    printf '{"body":"missing a guard","html_url":"https://x/%s","path":"z.tsx"}\n' "$i" >> "$IN/many.jsonl"
  done
  eq "上限生效" "5" "$(taxonomy_search missing-convention "$IN/many.jsonl" 5 | wc -l | tr -d ' ')"
}

# 撈不到足夠實例的類別要丟棄並記錄，不要硬產一條沒有出處的規則
test_class_with_too_few_hits_is_dropped() {
  printf '{"body":"nit: typo"}\n' > "$IN/sparse.jsonl"
  MRA_RULE_AGENT_CMD="$STUB/agent" bash "$MRA_DIR/scripts/extract-rules-taxonomy.sh" \
    --corpus "$IN/sparse.jsonl" --layer react --out "$OUT" >/dev/null 2>&1
  has "丟棄記錄有內容" "$(cat "$OUT/_dropped.tsv")" "missing-convention"
}

test_output_passes_validation() {
  for f in "$OUT"/*.md; do
    [ -e "$f" ] || continue
    rule_validate "$f" || fail "產出沒通過驗證：$f"
  done
  ok "所有產出都通過 rule_validate"
}
```

- [ ] **Step 3: 跑測試確認失敗**

Run: `bash tests/test_extract_rules_taxonomy.sh`
Expected: FAIL，`taxonomy_classes: command not found`

- [ ] **Step 4: 實作 `scripts/extract-rules-taxonomy.sh`**

```bash
#!/usr/bin/env bash
# B 路線：骨架來自回測分類，語料提供每一類的判準與反例。
#
# 與 A 路線的關鍵差異在 prompt：A 問「這群意見在講什麼共同問題」，B 問
# 「這一類問題在這個框架下長什麼樣、判準是什麼、什麼情況不該報」。
# 骨架已定，agent 的工作是填內容而不是決定主題。
set -uo pipefail
MRA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$MRA_DIR/lib/corpus-targets.sh"
source "$MRA_DIR/lib/rule-schema.sh"
source "$MRA_DIR/lib/taxonomy-classes.sh"

CORPUS=""; LAYER=""; OUT=""; MIN_HITS="${MRA_TAXONOMY_MIN_HITS:-3}"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --corpus) CORPUS="$2"; shift 2 ;;
    --layer)  LAYER="$2";  shift 2 ;;
    --out)    OUT="$2";    shift 2 ;;
    *) echo "用法：extract-rules-taxonomy.sh --corpus <jsonl> --layer <層> --out <目錄>" >&2; exit 1 ;;
  esac
done
[ -s "$CORPUS" ] || { echo "CORPUS_MISSING：${CORPUS}" >&2; exit 1; }
[ -n "$LAYER" ] || { echo "LAYER_MISSING" >&2; exit 1; }
mkdir -p "$OUT" "$OUT/_rejected" || exit 1
: > "$OUT/_dropped.tsv"

AGENT="${MRA_RULE_AGENT_CMD:-}"
[ -n "$AGENT" ] || { echo "MRA_RULE_AGENT_CMD 未設定" >&2; exit 1; }

produced=0; dropped=0; rejected=0
while IFS=$'\t' read -r class_id class_name _; do
  [ -n "$class_id" ] || continue
  hits="$(taxonomy_search "$class_id" "$CORPUS" 40)"
  n="$(printf '%s' "$hits" | grep -c . || true)"

  if [ "$n" -lt "$MIN_HITS" ]; then
    printf '%s\t%s\t%s\t撈到 %s 則，少於 %s\n' \
      "$class_id" "$class_name" "$LAYER" "$n" "$MIN_HITS" >> "$OUT/_dropped.tsv"
    dropped=$((dropped + 1)); continue
  fi

  payload="$(jq -n --arg c "$class_id" --arg name "$class_name" --arg l "$LAYER" \
    --argjson m "$(printf '%s' "$hits" | jq -s '.')" \
    '{class_id: $c, class_name: $name, layer: $l, members: $m}')"

  raw="$(printf '%s' "$payload" | MRA_RULE_PROMPT_PREFIX="$(taxonomy_prompt_prefix "$class_id" "$class_name" "$LAYER")" "$AGENT")" || {
    printf 'AGENT_FAILED\tclass=%s\n' "$class_id" >&2
    rejected=$((rejected + 1)); continue
  }

  tmp="$(mktemp "${TMPDIR:-/tmp}/rule.XXXXXX")" || exit 1
  printf '%s\n' "$raw" > "$tmp"
  id="$(rule_field "$tmp" id 2>/dev/null)"
  if [ -z "$id" ]; then
    cp "$tmp" "$OUT/_rejected/${LAYER}-${class_id}.md"
    printf 'RULE_REJECTED\tclass=%s\t產出沒有 id 欄位\n' "$class_id" >&2
    rm -f "$tmp"; rejected=$((rejected + 1)); continue
  fi

  dest="$OUT/${id}.md"
  mv "$tmp" "$dest" || { echo "MOVE_FAILED：${dest}" >&2; rm -f "$tmp"; exit 1; }
  if ! rule_validate "$dest"; then
    mv "$dest" "$OUT/_rejected/${LAYER}-${class_id}.md"
    printf 'RULE_REJECTED\tclass=%s\t沒通過驗證\n' "$class_id" >&2
    rejected=$((rejected + 1)); continue
  fi
  produced=$((produced + 1))
done < <(taxonomy_classes)

printf '%s 層：產出 %s、丟棄 %s（實例不足）、退回 %s（驗證不過）\n' \
  "$LAYER" "$produced" "$dropped" "$rejected"
```

在 `lib/taxonomy-classes.sh` 追加 prompt 前綴函式：

```bash
# B 路線的 prompt 前綴。骨架已定，agent 的工作是填內容而不是決定主題 ——
# 這是它與 A 路線最實質的差別，A 的 agent 要自己歸納群在講什麼。
taxonomy_prompt_prefix() {
  local class_id="$1" class_name="$2" layer="$3"
  cat <<EOF
以下是 ${layer} 層語料中，屬於「${class_name}」這一類的 review 意見。

這一類的定義：reviewer 指出的不是「這行寫錯了」，而是「這裡還應該做某件事」
或「這個情況沒有被考慮到」。回測資料顯示這是目前 reviewer 最大的盲區：
47 條漏抓有 51% 屬於這種形狀，六個 CRITICAL 有五個在裡面。

規則的 id 請用 ${layer}-${class_id} 開頭。

「觸發訊號」要寫成「diff 裡出現什麼樣的變更時，要去確認什麼」，
而不是「注意某某寫法」—— 前者會讓 reviewer 去看 diff 以外的東西，那正是
這一類問題需要的。
EOF
}
```

- [ ] **Step 5: 跑測試確認通過**

Run: `bash tests/test_extract_rules_taxonomy.sh`
Expected: PASS，8 個案例全綠

- [ ] **Step 6: 註冊 lib**

在 `bin/mra.sh` 的 `MRA_LIBS` 加入 `taxonomy-classes`。

Run: `bash tests/test_lib_loader.sh`
Expected: PASS

- [ ] **Step 7: 對真實語料跑一次**

```bash
OUT="${MRA_CORPUS_MATERIALIZED:-$HOME/.cache/mra-review-corpus-materialized}"
for layer in common nestjs rails react vue; do
  [ -s "$OUT/${layer}.jsonl" ] || continue
  MRA_RULE_AGENT_CMD="$PWD/scripts/rule-agent.sh" \
    bash scripts/extract-rules-taxonomy.sh \
      --corpus "$OUT/${layer}.jsonl" --layer "$layer" \
      --out agents/review-rules/taxonomy
done
bash scripts/rule-validate.sh agents/review-rules/taxonomy
```

Expected: 每層印出「產出 N、丟棄 M、退回 K」。最多 5 層 × 8 類 = 40 條規則，
實際會少於此（有些類在某些層撈不到足夠實例）。

- [ ] **Step 8: Commit**

```bash
git add lib/taxonomy-classes.sh scripts/extract-rules-taxonomy.sh \
        tests/test_extract_rules_taxonomy.sh agents/review-rules/taxonomy bin/mra.sh
git commit -m "feat(rules): B 路線依 finding 分類萃取規則

骨架來自回測資料的八類，語料提供判準與反例。與 A 路線的實質差別在 prompt：
A 問「這群意見在講什麼共同問題」，B 問「這一類問題在這個框架下長什麼樣」。

檢索關鍵詞是 reviewer 講這類問題時實際會用的字，不是分類名稱的翻譯 ——
沒有人會說 absence，他們說 should also、other routes have。"
```

---

### Task 6: 規則注入 persona

規則要能進到 review 才能回測。完整的「三個接點生成」是階段四的事，這裡只做
回測需要的最小機制：把該層的規則注入 persona 檔的 FOCUS 區塊。

persona 檔的格式（見 `agents/personas/*.md`）：`ROLE:` / `STYLE:` / `FOCUS:` /
`SCOPE NOTE:` / `METHOD:` / `OUTPUT FORMAT:`。注入點是 FOCUS 之後、SCOPE NOTE 之前。

**Files:**
- Create: `lib/rule-inject.sh`
- Create: `tests/test_rule_inject.sh`
- Modify: `bin/mra.sh`（`MRA_LIBS` 加 `rule-inject`）

**Interfaces:**
- Consumes: `rule_field`、`rule_section`（Task 2）
- Produces:
  - `rule_render_block <rules_dir> <layer>` → 把該層所有規則渲染成一段可插入 persona 的文字
  - `rule_inject_persona <persona_file> <block> <out_file>` → 產出注入後的 persona
  - `rule_inject_all <rules_dir> <layer> <out_persona_dir>` → 對五個 persona 各做一次

- [ ] **Step 1: 寫失敗的測試**

```bash
# tests/test_rule_inject.sh

test_block_contains_trigger_and_criteria() {
  local block; block="$(rule_render_block "$FIX/rules" nestjs)"
  has "含觸發訊號" "$block" "@Injectable"
  has "含判準" "$block" "request-scoped provider"
}

test_block_excludes_other_layers() {
  local block; block="$(rule_render_block "$FIX/rules" react)"
  lacks "不含 nestjs 層的規則" "$block" "@Injectable"
}

test_block_omits_sources() {
  # 出處是給人查的，塞進 prompt 只是佔 token
  local block; block="$(rule_render_block "$FIX/rules" nestjs)"
  lacks "不含 URL" "$block" "https://github.com"
}

test_inject_preserves_original_sections() {
  rule_inject_persona "$FIX/persona.md" "$(rule_render_block "$FIX/rules" nestjs)" "$OUT/p.md"
  has "ROLE 還在" "$(cat "$OUT/p.md")" "ROLE:"
  has "METHOD 還在" "$(cat "$OUT/p.md")" "METHOD:"
  has "OUTPUT FORMAT 還在" "$(cat "$OUT/p.md")" "OUTPUT FORMAT:"
}

test_inject_places_block_after_focus() {
  local focus_line inject_line scope_line
  focus_line="$(grep -n '^FOCUS:' "$OUT/p.md" | cut -d: -f1)"
  inject_line="$(grep -n 'RULESET' "$OUT/p.md" | head -1 | cut -d: -f1)"
  scope_line="$(grep -n '^SCOPE NOTE:' "$OUT/p.md" | cut -d: -f1)"
  [ "$focus_line" -lt "$inject_line" ] && [ "$inject_line" -lt "$scope_line" ] \
    && ok "注入位置在 FOCUS 與 SCOPE NOTE 之間" \
    || fail "注入位置不對：focus=$focus_line inject=$inject_line scope=$scope_line"
}

# persona 沒有 FOCUS 區塊時要報錯，不要默默 append 到檔尾
test_persona_without_focus_fails_loudly() {
  printf 'ROLE: x\nMETHOD:\n1. y\n' > "$OUT/no-focus.md"
  local out rc
  out="$(rule_inject_persona "$OUT/no-focus.md" "block" "$OUT/z.md" 2>&1)"; rc=$?
  [ "$rc" -ne 0 ] && ok "沒有 FOCUS 退出碼非 0" || fail "應退出非 0"
  has "印出 PERSONA_NO_FOCUS" "$out" "PERSONA_NO_FOCUS"
}

test_empty_ruleset_produces_no_block() {
  mkdir -p "$OUT/empty-rules"
  local block; block="$(rule_render_block "$OUT/empty-rules" nestjs)"
  eq "空規則集產出空字串" "" "$block"
}

# 注入是冪等的：同一個 persona 注入兩次不該疊兩份規則
test_inject_is_idempotent() {
  local block; block="$(rule_render_block "$FIX/rules" nestjs)"
  rule_inject_persona "$FIX/persona.md" "$block" "$OUT/once.md"
  rule_inject_persona "$OUT/once.md" "$block" "$OUT/twice.md"
  eq "RULESET 標記只出現一次" "1" "$(grep -c 'BEGIN RULESET' "$OUT/twice.md")"
}
```

- [ ] **Step 2: 跑測試確認失敗**

Run: `bash tests/test_rule_inject.sh`
Expected: FAIL，`rule_render_block: command not found`

- [ ] **Step 3: 實作 `lib/rule-inject.sh`**

```bash
#!/usr/bin/env bash
# 把規則注入 persona 的 FOCUS 區塊。這是回測需要的最小機制，完整的三個接點
# 生成是階段四的事。
#
# 出處不進 prompt：那是給人查的，塞進去只是佔 token，而 persona 的 prompt
# 已經要放 diff 與 PKB。
#
# 用可辨識的界線標記（BEGIN/END RULESET）而不是直接 append：注入要能重複執行
# 而不疊加，否則反覆回測會讓 prompt 越長越誇張。

RULE_BLOCK_BEGIN="# --- BEGIN RULESET (auto-generated, do not edit) ---"
RULE_BLOCK_END="# --- END RULESET ---"

rule_render_block() {
  local dir="$1" layer="$2"
  [ -d "$dir" ] || return 0
  local out="" f
  for f in "$dir"/*.md; do
    [ -e "$f" ] || continue
    local l; l="$(rule_field "$f" layer 2>/dev/null)"
    # common 層的規則對每一層都適用
    [ "$l" = "$layer" ] || [ "$l" = "common" ] || continue
    local id sev trigger criteria counter
    id="$(rule_field "$f" id)"
    sev="$(rule_field "$f" severity_default)"
    trigger="$(rule_section "$f" 觸發訊號 | tr -d '\r' | sed '/^$/d')"
    criteria="$(rule_section "$f" 判準 | tr -d '\r' | sed '/^$/d')"
    counter="$(rule_section "$f" 反例 | tr -d '\r' | sed '/^$/d')"
    out="${out}
- [${id}] 預設嚴重度 ${sev}
  觸發：${trigger}
  判準：${criteria}
  不要報：${counter}
"
  done
  [ -n "$(printf '%s' "$out" | tr -d '[:space:]')" ] || return 0
  printf '%s\n%s\n%s\n' "$RULE_BLOCK_BEGIN" \
    "額外檢查項（來自團隊規則集，與上面的 FOCUS 並列，不取代它）：${out}" \
    "$RULE_BLOCK_END"
}

rule_inject_persona() {
  local persona="$1" block="$2" out="$3"
  [ -f "$persona" ] || { printf 'PERSONA_MISSING\t%s\n' "$persona" >&2; return 1; }
  grep -q '^FOCUS:' "$persona" || {
    printf 'PERSONA_NO_FOCUS\t%s\t找不到 FOCUS: 區塊，無法決定注入位置\n' "$persona" >&2
    return 1
  }

  local tmp
  tmp="$(mktemp "${TMPDIR:-/tmp}/persona.XXXXXX")" || return 1
  # 先剝掉舊的 RULESET 區塊再注入 —— 沒有這步的話重複執行會疊加
  awk -v b="$RULE_BLOCK_BEGIN" -v e="$RULE_BLOCK_END" '
    $0 == b { skip = 1; next }
    $0 == e { skip = 0; next }
    !skip' "$persona" > "$tmp" || { rm -f "$tmp"; return 1; }

  local tmp2
  tmp2="$(mktemp "${TMPDIR:-/tmp}/persona2.XXXXXX")" || { rm -f "$tmp"; return 1; }
  RULE_BLOCK="$block" awk '
    /^SCOPE NOTE:/ && !done { print ENVIRON["RULE_BLOCK"]; print ""; done = 1 }
    { print }
    END { if (!done) print ENVIRON["RULE_BLOCK"] }' "$tmp" > "$tmp2" \
    || { rm -f "$tmp" "$tmp2"; return 1; }

  mv "$tmp2" "$out" || { printf 'MOVE_FAILED\t%s\n' "$out" >&2; rm -f "$tmp" "$tmp2"; return 1; }
  rm -f "$tmp"
}

rule_inject_all() {
  local rules_dir="$1" layer="$2" out_dir="$3"
  local src="${MRA_DIR}/agents/personas"
  mkdir -p "$out_dir" || return 1
  local block; block="$(rule_render_block "$rules_dir" "$layer")"
  local p n=0
  for p in "$src"/*.md; do
    [ -e "$p" ] || continue
    [ "$(basename "$p")" = "README.md" ] && continue
    rule_inject_persona "$p" "$block" "$out_dir/$(basename "$p")" || return 1
    n=$((n + 1))
  done
  printf '%s\n' "$n"
}
```

- [ ] **Step 4: 跑測試確認通過**

Run: `bash tests/test_rule_inject.sh`
Expected: PASS，8 個案例全綠

- [ ] **Step 5: 註冊 lib 並 commit**

在 `bin/mra.sh` 的 `MRA_LIBS` 加入 `rule-inject`。

```bash
git add lib/rule-inject.sh tests/test_rule_inject.sh bin/mra.sh
git commit -m "feat(rules): 把規則注入 persona 的 FOCUS 區塊

用 BEGIN/END RULESET 界線標記而不是直接 append：注入要能重複執行而不疊加，
否則反覆回測會讓 prompt 越長越誇張。

出處不進 prompt：那是給人查的，塞進去只佔 token，而 persona 的 prompt
已經要放 diff 與 PKB。"
```

---

### Task 7: 讓 persona 目錄可覆寫

`lib/personas.sh:4` 的 `_personas_dir()` 把路徑寫死成 `$mra_dir/agents/personas`，
沒有覆蓋點。Task 8 的回測要指向注入規則後的 persona 副本，需要這個覆蓋點。

改動要小、預設行為不變。這是動到 review 主流程的檔案，Slack gateway 也會走到。

**Files:**
- Modify: `lib/personas.sh:4-8`
- Create: `tests/test_personas_dir_override.sh`

**Interfaces:**
- Produces: `_personas_dir()` 在 `MRA_PERSONAS_DIR` 有設且是目錄時回傳它，否則回傳原本的路徑

- [ ] **Step 1: 寫失敗的測試**

```bash
# tests/test_personas_dir_override.sh

test_default_unchanged() {
  unset MRA_PERSONAS_DIR
  local d; d="$(_personas_dir)"
  has "預設指向 agents/personas" "$d" "agents/personas"
}

test_env_override_takes_effect() {
  mkdir -p "$TMP/custom"
  local d; d="$(MRA_PERSONAS_DIR="$TMP/custom" _personas_dir)"
  eq "env 覆蓋生效" "$TMP/custom" "$d"
}

# 指到不存在的目錄時要退回預設，不是讓 load_persona 噴 not found ——
# 打錯路徑會讓整輪回測跑在沒有規則的 persona 上，而且看起來像正常執行
test_nonexistent_override_falls_back_with_warning() {
  local out d
  d="$(MRA_PERSONAS_DIR="$TMP/does-not-exist" _personas_dir 2>"$TMP/warn")"
  has "退回預設路徑" "$d" "agents/personas"
  has "印出警告" "$(cat "$TMP/warn")" "PERSONAS_DIR_INVALID"
}

test_load_persona_reads_from_override() {
  mkdir -p "$TMP/custom"
  printf 'ROLE: Custom\nFOCUS:\n- x\n' > "$TMP/custom/security-auditor.md"
  local body; body="$(MRA_PERSONAS_DIR="$TMP/custom" load_persona security-auditor)"
  has "讀到覆蓋目錄的內容" "$body" "ROLE: Custom"
}
```

- [ ] **Step 2: 跑測試確認失敗**

Run: `bash tests/test_personas_dir_override.sh`
Expected: FAIL，`test_env_override_takes_effect` 拿到的是預設路徑

- [ ] **Step 3: 改 `lib/personas.sh`**

```bash
# MRA_PERSONAS_DIR 讓呼叫端指向另一份 persona（回測用來指向注入規則後的副本）。
# 指到不存在的目錄時退回預設並印警告，不是直接用下去：打錯路徑會讓整輪回測
# 跑在沒有規則的 persona 上，而且看起來像正常執行 —— 那正是這個專案一路在防的
# 「失敗長得像一個合理的結果」。
_personas_dir() {
  local mra_dir
  mra_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  local override="${MRA_PERSONAS_DIR:-}"
  if [[ -n "$override" ]]; then
    if [[ -d "$override" ]]; then
      echo "$override"
      return 0
    fi
    echo "PERSONAS_DIR_INVALID：MRA_PERSONAS_DIR=${override} 不是目錄，改用預設" >&2
  fi
  echo "$mra_dir/agents/personas"
}
```

- [ ] **Step 4: 跑測試確認通過**

Run: `bash tests/test_personas_dir_override.sh`
Expected: PASS，4 個案例全綠

- [ ] **Step 5: 確認既有測試沒退化**

Run: `bash tests/test_review_json_flag.sh` 與全套 `tests/test_review_*.sh`
Expected: 全綠。這個改動動到 review 主流程，Slack gateway 也會走到，
預設行為不變是硬要求。

- [ ] **Step 6: Commit**

```bash
git add lib/personas.sh tests/test_personas_dir_override.sh
git commit -m "feat(personas): 加 MRA_PERSONAS_DIR 覆蓋點

回測要指向注入規則後的 persona 副本。預設行為完全不變。

指到不存在的目錄時退回預設並印警告，不是直接用下去：打錯路徑會讓整輪回測
跑在沒有規則的 persona 上，而且看起來像正常執行。"
```

---

### Task 8: 帶規則回測並比較

兩套規則各跑一輪，跟階段二的 C 基準線（0.85／0.69）比。用 C 不用 A：規則注入的是
persona，而 A 走 single-pass 不讀 persona。

**Files:**
- Create: `scripts/run-rule-backtest.sh`
- Create: `tests/test_run_rule_backtest.sh`
- Create（產出）: `docs/superpowers/notes/2026-rule-extraction-comparison.md`

**Interfaces:**
- Consumes: `rule_inject_all`（Task 6）、`MRA_PERSONAS_DIR`（Task 7）、
  `scripts/run-backtest.sh`（階段二）
- Produces: `~/.cache/mra-review-benchmark/runs/rules-{tfidf,taxonomy}/summary.json`

- [ ] **Step 1: 寫失敗的測試**

```bash
# tests/test_run_rule_backtest.sh
# 用 stub 取代 run-backtest.sh，驗流程不驗 review 品質。
# stub 把收到的 argv 與環境變數寫進紀錄檔供斷言。

write_backtest_stub() {
  cat > "$STUB/backtest" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" > "$STUB/argv.log"
printf 'MRA_PERSONAS_DIR=%s\n' "\${MRA_PERSONAS_DIR:-<unset>}" > "$STUB/env.log"
printf 'MRA_REVIEW_PERSONA_MAX_TURNS=%s\n' "\${MRA_REVIEW_PERSONA_MAX_TURNS:-<unset>}" >> "$STUB/env.log"
exit 0
SH
  chmod +x "$STUB/backtest"
}

test_injects_before_running_backtest() {
  MRA_BACKTEST_SCRIPT="$STUB/backtest" MRA_RULE_PERSONA_DIR="$TMP" \
    bash "$MRA_DIR/scripts/run-rule-backtest.sh" \
      --rules "$FIX/rules" --label rules-test >/dev/null 2>&1
  local injected="$TMP/personas-rules-test/security-auditor.md"
  [ -f "$injected" ] && ok "產出了注入後的 persona" || fail "沒有注入後的 persona"
  has "注入後含 RULESET" "$(cat "$injected")" "BEGIN RULESET"
}

test_points_persona_dir_at_injected_copy() {
  has "MRA_PERSONAS_DIR 指向注入後的目錄" "$(cat "$STUB/env.log")" "personas-rules-test"
}

test_passes_persona_turns_20() {
  has "persona 輪數與階段二的 C 一致" "$(cat "$STUB/env.log")" "MRA_REVIEW_PERSONA_MAX_TURNS=20"
}

test_refuses_when_rules_dir_empty() {
  mkdir -p "$TMP/no-rules"
  local out rc
  out="$(bash "$MRA_DIR/scripts/run-rule-backtest.sh" --rules "$TMP/no-rules" \
    --label x 2>&1)"; rc=$?
  [ "$rc" -ne 0 ] && ok "空規則集退出碼非 0" || fail "應退出非 0"
  has "印出 NO_RULES" "$out" "NO_RULES"
}

# 沒驗證過的規則不該拿去跑 —— 跑完才發現規則格式壞掉等於白燒幾小時
test_validates_rules_before_running() {
  rm -f "$STUB/argv.log"
  mkdir -p "$TMP/bad-rules"
  printf 'not a rule file\n' > "$TMP/bad-rules/x.md"
  local out rc
  out="$(MRA_BACKTEST_SCRIPT="$STUB/backtest" \
    bash "$MRA_DIR/scripts/run-rule-backtest.sh" --rules "$TMP/bad-rules" \
    --label y 2>&1)"; rc=$?
  [ "$rc" -ne 0 ] && ok "規則不合格退出碼非 0" || fail "應退出非 0"
  has "印出 RULES_INVALID" "$out" "RULES_INVALID"
  [ ! -f "$STUB/argv.log" ] && ok "沒有呼叫 backtest" || fail "不該呼叫 backtest"
}

test_tolerance_is_passed_through() {
  MRA_BACKTEST_SCRIPT="$STUB/backtest" MRA_RULE_PERSONA_DIR="$TMP" \
    bash "$MRA_DIR/scripts/run-rule-backtest.sh" \
      --rules "$FIX/rules" --label t15 --tolerance 15 >/dev/null 2>&1
  has "容差有傳下去" "$(cat "$STUB/argv.log")" "--tolerance 15"
}
```

- [ ] **Step 2: 跑測試確認失敗**

Run: `bash tests/test_run_rule_backtest.sh`
Expected: FAIL，找不到 `scripts/run-rule-backtest.sh`

- [ ] **Step 3: 實作 `scripts/run-rule-backtest.sh`**

```bash
#!/usr/bin/env bash
# 帶規則跑回測。注入 persona → 指向注入後的目錄 → 跑階段二的 run-backtest.sh。
#
# 先驗規則再跑：跑完才發現規則格式壞掉等於白燒幾小時。這是階段二學到的
# 「失敗要早、要響」的同一條原則。
#
# 執行條件與階段二的 C 完全一致（personas + claude + sonnet + persona 20 輪），
# 只有規則不同 —— 否則比較出來的差異可能來自條件而不是規則。
set -uo pipefail
MRA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$MRA_DIR/lib/corpus-targets.sh"
source "$MRA_DIR/lib/rule-schema.sh"
source "$MRA_DIR/lib/rule-inject.sh"

RULES=""; LABEL=""; TOL="${MRA_RULE_BACKTEST_TOL:-5}"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --rules) RULES="$2"; shift 2 ;;
    --label) LABEL="$2"; shift 2 ;;
    --tolerance) TOL="$2"; shift 2 ;;
    *) echo "用法：run-rule-backtest.sh --rules <目錄> --label <名稱> [--tolerance N]" >&2; exit 1 ;;
  esac
done
[ -n "$RULES" ] && [ -n "$LABEL" ] || { echo "缺 --rules 或 --label" >&2; exit 1; }

n_rules="$(ls "$RULES"/*.md 2>/dev/null | wc -l | tr -d ' ')"
[ "$n_rules" -gt 0 ] || { echo "NO_RULES：${RULES} 底下沒有規則檔" >&2; exit 1; }

bad=0
for f in "$RULES"/*.md; do
  rule_validate "$f" || bad=$((bad + 1))
done
[ "$bad" -eq 0 ] || {
  echo "RULES_INVALID：${bad} 個規則檔沒通過驗證，先修好再跑（見上方訊息）" >&2
  exit 1
}

INJECTED="${MRA_RULE_PERSONA_DIR:-${TMPDIR:-/tmp}}/personas-${LABEL}"
# 只注入 common 層的規則：回測涵蓋 rails／react／nestjs 三種 repo，而 persona
# 目錄是全域共用的，沒辦法依 repo 切換。分層注入是階段四的事。
rule_inject_all "$RULES" common "$INJECTED" >/dev/null || {
  echo "INJECT_FAILED" >&2; exit 1; }

echo "規則 ${n_rules} 條，注入後的 persona 在 ${INJECTED}"

BACKTEST="${MRA_BACKTEST_SCRIPT:-$MRA_DIR/scripts/run-backtest.sh}"
MRA_BACKTEST_CMD="$MRA_DIR/scripts/backtest-review-adapter.sh" \
MRA_BACKTEST_REVIEW_MODE=personas \
MRA_REVIEW_PERSONA_MAX_TURNS=20 \
MRA_PERSONAS_DIR="$INJECTED" \
  bash "$BACKTEST" --label "$LABEL" --tolerance "$TOL"
```

- [ ] **Step 4: 跑測試確認通過**

Run: `bash tests/test_run_rule_backtest.sh`
Expected: PASS，6 個案例全綠

- [ ] **Step 5: 兩套規則各跑一輪**

```bash
bash scripts/run-rule-backtest.sh --rules agents/review-rules/tfidf --label rules-tfidf
bash scripts/run-rule-backtest.sh --rules agents/review-rules/taxonomy --label rules-taxonomy
```

每輪約 5 小時、38 個 PR。跑之前確認 `gh auth switch --user acme-bot`
與 Claude 登入都有效 —— 階段二有一輪因為 OAuth 中途過期而 34 筆失敗，
覆蓋率下限（預設 0.8）會擋下那種情況但白燒的 token 拿不回來。

- [ ] **Step 6: 兩個容差各重算一次**

```bash
for pair in "rules-tfidf tfidf" "rules-taxonomy taxonomy"; do
  set -- $pair
  for tol in 5 15; do
    bash scripts/run-rule-backtest.sh --rules "agents/review-rules/$2" \
      --label "$1" --tolerance "$tol"
    cp "$HOME/.cache/mra-review-benchmark/runs/$1/summary.json" \
       "$HOME/.cache/mra-review-benchmark/runs/$1/summary-tol${tol}.json"
  done
done
```

重算不會重叫 review（輸出都存著，`-s` 判定會跳過），成本接近零。

- [ ] **Step 7: 確認四輪的 candidates_sha 一致**

```bash
for l in baseline-personas rules-tfidf rules-taxonomy; do
  printf '%s\t%s\n' "$l" \
    "$(jq -r '.candidates_sha' "$HOME/.cache/mra-review-benchmark/runs/$l/summary.json")"
done
```

Expected: 三個都是 `7a8226ee333100a9`。不一致代表候選集在中途被改過，
那樣的比較無效，要找出是哪一步動到它。

- [ ] **Step 8: 寫比較文件**

`docs/superpowers/notes/2026-rule-extraction-comparison.md`，必須包含：

1. 三組數字的表格（C 基準線、A 路線、B 路線 × 兩個容差）
2. 每套規則的條數、被丟棄的群／類數與原因
3. `candidates_sha` 四輪一致的確認
4. 未對應 comment 的抽樣判讀，照 `unmatched-sampling-plan.md` 的規則：
   CRITICAL 全讀、HIGH 每 2 取 1、MEDIUM 每 4 取 1，分成「我漏判／無修復
   commit／誤報」三類，不確定的一律歸中間類並標明
5. 明確寫出「哪一套比較好、差多少、以及這個差距是否大到足以支持結論」

第 5 點最重要。C 基準線是 0.85／0.69。如果兩套規則都只動一到兩個百分點，
那結論是「規則萃取的方式不是瓶頸」，而不是「某一套比較好」—— 那個結論
對階段四同樣有價值，而且會省下大量往錯方向調的時間。

判斷差距是否顯著的參考：基準集 54 條 finding，一條約等於 1.9 個百分點。
兩個百分點以內的差距等於一條 finding 的翻轉，不足以支持任何結論。

- [ ] **Step 9: Commit**

```bash
git add scripts/run-rule-backtest.sh tests/test_run_rule_backtest.sh \
        docs/superpowers/notes/2026-rule-extraction-comparison.md
git commit -m "feat(rules): 帶規則回測並比較兩條萃取路線

執行條件與階段二的 C 完全一致，只有規則不同 —— 否則比較出來的差異可能
來自條件而不是規則。

先驗規則再跑：跑完才發現規則格式壞掉等於白燒幾小時。"
```

---

## 執行順序與相依

```
Task 1（語料落地）─┐
Task 2（schema）──┼─→ Task 3 → Task 4（A 路線）─┐
                  ├─→ Task 5（B 路線）──────────┼─→ Task 8（回測比較）
                  └─→ Task 6（注入）─ Task 7 ───┘
```

Task 1 與 2 可並行。Task 3→4 與 Task 5 可並行。Task 8 要等前面全部完成。

## 這個計畫刻意不做的事

**不做三個接點的生成。** 那是階段四。這裡只做回測需要的最小注入機制。

**不做分層注入。** 回測涵蓋 rails／react／nestjs 三種 repo，但 persona 目錄是
全域的。Task 8 只注入 common 層的規則。分層注入需要在 review 流程裡依 repo
決定載入哪些規則，那是階段四的工作。

**不調任何回測條件。** 執行條件與階段二的 C 完全一致，包括 persona 20 輪這個
偏離。要比的是規則，不是條件。

**不重建候選集。** 現有的 `candidates.json` 是 38 筆人工判讀的成果。階段二已知
`sort=updated` 的抽樣不可複現，那個修正是給階段四之後用的，這裡不動它。
