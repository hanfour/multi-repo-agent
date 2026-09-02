#!/usr/bin/env bash
# 回測基準集的 blame 歸因：fix commit 改到的舊行，是不是受審 PR 寫的。
#
# 現行 lib/backtest-groundtruth.sh 的 backtest_overlap 是拿 fix commit 的行號
# 區間跟 PR 的行號區間取交集。交集只證明「兩者改到同一區域」，沒證明「fix 修
# 的是 PR 引入的東西」：合併後別人的改動讓缺陷成立、fix 改的是 PR 沒動過的
# context 行，都會通過交集。人工定案的 54 條裡交集的精確率 0.37，改用這裡
# 的歸因是 0.55，再加 5 天門檻是 0.71（docs/superpowers/notes/
# 2026-persona-convention-coverage.md「產生方式的根因」）。
#
# 作法（SZZ 式）：對 fix commit 在某個檔案的每個 hunk，取舊檔側被改的行，在
# fix^1 上 blame，看指到的 commit 是不是受審 PR 的 commit。PR 的 commit 集合：
#   squash／rebase 合併：merge commit 只有一個父，集合就是它自己
#   merge 合併：兩個父，集合是 rev-list mc^1..mc
# 純新增的 hunk 沒有舊行可 blame，改 blame 插入點上下兩行當錨點。
#
# 全部走本機 clone，不打 GitHub API：blame 一個檔案幾十毫秒，API 一次幾百
# 毫秒還吃額度。呼叫端要保證 merge commit 與 fix commit 都在本機（回測跑
# review 的 adapter 本來就需要本機 clone）。
#
# 每個函式：查不到 commit／repo 就回非 0，不能靜默回空——空陣列是「查過、
# 沒有可歸因的行」，跟「查不到」是兩件事，混在一起會讓候選悄悄消失。

# 受審 PR 的 commit 集合，一行一個 sha。
backtest_pr_commit_set() {
  local repo_dir="$1" mc="$2" parents
  parents="$(git -C "$repo_dir" rev-list --parents -n1 "$mc" 2>/dev/null)" || return 1
  [[ -n "$parents" ]] || return 1
  # rev-list --parents 印「自己 父1 父2…」，兩個欄位就是單親
  if [[ "$(printf '%s' "$parents" | wc -w | tr -d ' ')" -le 2 ]]; then
    git -C "$repo_dir" rev-parse "$mc"
  else
    git -C "$repo_dir" rev-list "${mc}^1..${mc}"
  fi
}

# PR 當時的版本：人工填 expected_findings 的 line 用的座標（review 也是審
# 這個版本）。squash 合併就是 merge commit 本身（樹 = base + PR 的改動）；
# merge 合併是第二個父，也就是分支 head。
backtest_pr_version_ref() {
  local repo_dir="$1" mc="$2" parents
  parents="$(git -C "$repo_dir" rev-list --parents -n1 "$mc" 2>/dev/null)" || return 1
  [[ -n "$parents" ]] || return 1
  if [[ "$(printf '%s' "$parents" | wc -w | tr -d ' ')" -le 2 ]]; then
    printf '%s\n' "$mc"
  else
    printf '%s^2\n' "$mc"
  fi
}

# fix commit 在某個檔案的 hunk，一行一個，TSV：kind old_from old_to new_from new_to
#   mod：舊檔側有被改的行，old_from..old_to 就是那些行
#   add：純新增，舊檔側沒有行，old_from..old_to 是插入點上下兩行（錨點）
# 新增的檔案（舊檔側是 0,0）沒有任何舊行可歸因，不產生 hunk。
# --no-renames：改名的檔案拆成一刪一增，不然新路徑在 fix^1 上 blame 不到。
backtest_fix_hunks() {
  local repo_dir="$1" fix="$2" path="$3"
  git -C "$repo_dir" diff -U0 --no-renames "${fix}^1" "$fix" -- "$path" 2>/dev/null | awk '
    /^@@ / {
      a = $2; c = $3; sub(/^-/, "", a); sub(/^\+/, "", c)
      n = split(a, A, ","); of = A[1] + 0; ol = (n > 1 ? A[2] + 0 : 1)
      n = split(c, C, ","); nf = C[1] + 0; nl = (n > 1 ? C[2] + 0 : 1)
      nt = nf + (nl > 0 ? nl : 1) - 1
      if (ol > 0)      printf "mod\t%d\t%d\t%d\t%d\n", of, of + ol - 1, nf, nt
      else if (of > 0) printf "add\t%d\t%d\t%d\t%d\n", of, of + 1, nf, nt
    }'
  return "${PIPESTATUS[0]}"
}

# fix^1 上該檔案的 blame，TSV：final_line sha orig_line content
# orig_line 是那一行在 sha 那個 commit 裡的行號；content 是行內容（去掉
# porcelain 的前導 tab，內容本身的 tab 保留）。-w：只改空白的 commit 不算作者。
_backtest_blame_map() {
  local repo_dir="$1" rev="$2" path="$3"
  git -C "$repo_dir" blame -w --line-porcelain "$rev" -- "$path" 2>/dev/null | awk '
    /^[0-9a-f]+ [0-9]+ [0-9]+/ && length($1) == 40 { sha = $1; orig = $2; fin = $3; next }
    /^\t/ { printf "%s\t%s\t%s\t%s\n", fin, sha, orig, substr($0, 2) }'
  return "${PIPESTATUS[0]}"
}

# 每個 hunk 的歸因，JSON 陣列：
#   {path, kind, old_from, old_to, new_from, new_to, n, to_pr, ratio, head_lines}
#   n        舊檔側實際存在的被改行（或錨點）數
#   to_pr    其中 blame 指到受審 PR 的行數
#   ratio    to_pr / n，兩位小數
#   head_lines 指到 PR 的那些行，在 PR 當時版本（backtest_pr_version_ref）的
#            行號。blame 指到的 commit 就是那個版本時直接用 orig_line；不是的
#            話（merge 合併、分支上較早的 commit）拿行內容在那個版本裡找，多個
#            相同內容取離 orig_line 最近的一個，找不到就略過。
# 新增的檔案（fix^1 沒有這個路徑）回 []。commit 不在本機回非 0。
backtest_blame_hunks() {
  local repo_dir="$1" mc="$2" fix="$3" path="$4"
  local prset ver ver_sha hunks map vtmp ptmp mtmp htmp rows
  git -C "$repo_dir" cat-file -e "${fix}^{commit}" 2>/dev/null || return 1
  prset="$(backtest_pr_commit_set "$repo_dir" "$mc")" || return 1
  ver="$(backtest_pr_version_ref "$repo_dir" "$mc")" || return 1
  ver_sha="$(git -C "$repo_dir" rev-parse "$ver" 2>/dev/null)" || return 1

  if ! git -C "$repo_dir" cat-file -e "${fix}^1:${path}" 2>/dev/null; then
    printf '[]\n'; return 0
  fi
  hunks="$(backtest_fix_hunks "$repo_dir" "$fix" "$path")" || return 1
  if [[ -z "$hunks" ]]; then printf '[]\n'; return 0; fi
  map="$(_backtest_blame_map "$repo_dir" "${fix}^1" "$path")" || return 1

  ptmp="$(mktemp)"; mtmp="$(mktemp)"; vtmp="$(mktemp)"; htmp="$(mktemp)"
  printf '%s\n' "$prset" > "$ptmp"
  printf '%s\n' "$map" > "$mtmp"
  printf '%s\n' "$hunks" > "$htmp"
  # PR 當時版本裡沒有這個檔案（PR 沒動過它）就沒有行號可對，留空檔
  git -C "$repo_dir" show "${ver}:${path}" > "$vtmp" 2>/dev/null || : > "$vtmp"

  rows="$(awk -F'\t' -v ver_sha="$ver_sha" -v pf="$ptmp" -v mf="$mtmp" -v vf="$vtmp" '
    function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
    function headline(l,    best, d, dd, i) {
      if (S[l] == ver_sha) return O[l]
      best = 0; d = -1
      for (i = 1; i <= nv; i++) {
        if (V[i] != C[l]) continue
        dd = (i > O[l] ? i - O[l] : O[l] - i)
        if (d < 0 || dd < d) { d = dd; best = i }
      }
      return best
    }
    FILENAME == pf { P[$1] = 1; next }
    FILENAME == mf {
      fin = $1 + 0; S[fin] = $2; O[fin] = $3 + 0
      c = $4; for (i = 5; i <= NF; i++) c = c "\t" $i
      C[fin] = trim(c); next
    }
    FILENAME == vf { nv++; V[nv] = trim($0); next }
    {
      kind = $1; of = $2 + 0; ot = $3 + 0; nf = $4 + 0; nt = $5 + 0
      n = 0; tp = 0; hl = ""
      for (l = of; l <= ot; l++) {
        if (!(l in S)) continue
        n++
        if (!(S[l] in P)) continue
        tp++
        h = headline(l)
        if (h > 0) hl = hl (hl == "" ? "" : ",") h
      }
      printf "%s\t%d\t%d\t%d\t%d\t%d\t%d\t%s\n", kind, of, ot, nf, nt, n, tp, hl
    }' "$ptmp" "$mtmp" "$vtmp" "$htmp")"
  local awk_rc=$?
  rm -f "$ptmp" "$mtmp" "$vtmp" "$htmp"
  [[ $awk_rc -eq 0 ]] || return 1

  local kind of ot nf nt n tp hl
  while IFS=$'\t' read -r kind of ot nf nt n tp hl; do
    [[ -n "$kind" ]] || continue
    jq -cn --arg path "$path" --arg kind "$kind" --arg hl "$hl" \
      --argjson of "$of" --argjson ot "$ot" --argjson nf "$nf" --argjson nt "$nt" \
      --argjson n "$n" --argjson tp "$tp" '
      {path: $path, kind: $kind, old_from: $of, old_to: $ot, new_from: $nf, new_to: $nt,
       n: $n, to_pr: $tp,
       ratio: (if $n > 0 then (($tp / $n * 100) | round) / 100 else 0 end),
       head_lines: (if $hl == "" then [] else ($hl | split(",") | map(tonumber) | unique) end)}'
  done <<< "$rows" | jq -s '.'
}

# fix commit 距 PR 合併的天數，一位小數。兩個都是 ISO 8601（GitHub 的
# merged_at 是 Z 結尾，git 的 %cI 帶時區位移）。
backtest_gap_days() {
  local merged="$1" fixed="$2"
  python3 -c '
import datetime, sys
def parse(s):
    return datetime.datetime.fromisoformat(s.replace("Z", "+00:00"))
try:
    gap = (parse(sys.argv[2]) - parse(sys.argv[1])).total_seconds() / 86400
except ValueError as e:
    print(f"GAP_DATE_INVALID: {e}", file=sys.stderr)
    sys.exit(1)
print(f"{gap:.1f}")
' "$merged" "$fixed"
}
