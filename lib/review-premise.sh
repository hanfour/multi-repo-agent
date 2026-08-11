#!/usr/bin/env bash
# A finding may not invent the convention it says the code violates.
#
# Measured over 80 reviewed pull requests: every one of the five reviews a
# human dismissed rested on an unchecked premise, and three of the five were
# the same invented decorator — reported as [HIGH] and [CRITICAL] on three
# different pull requests, each time as "not annotated `@RequirePermission`
# like the existing controller convention". Code search: RequirePermission 0
# occurrences, PermissionGuard 0, AuthGuard 9. A reviewer refuted it with one
# grep.
#
# Across the same 31 findings, a concrete file/symbol/line is cited 2 times and
# convention-asserting language appears 16 times. Findings assert rather than
# cite — which is exactly what makes the assertion mechanically checkable: if a
# finding says a symbol is the established convention, the symbol has to be
# somewhere in the repository.
#
# Deliberately narrow. Two things must both hold before anything is dropped:
#   1. the finding claims the thing ALREADY EXISTS (convention / existing /
#      "like the others"), rather than proposing something new, and
#   2. the symbol it names is nowhere in the tree.
# Either alone proves nothing. Proposing a `RetryPolicy` that does not exist yet
# is a normal suggestion; naming a guard that does exist is a normal citation.

# Phrases that assert an existing practice, in the languages reviews are written
# in here. Proposal words ("建議新增", "consider adding") are deliberately absent.
_MRA_PREMISE_CLAIM_RE='慣例|既有|依專案架構|其他[^。]{0,12}(controller|handler|模組|檔案)|一致地|同樣地|convention|existing|already (uses|has)|unlike the (other|existing)|like the (other|rest|existing)|as elsewhere|standard practice|codebase|沒有加上|沒有標註|未標註|未套用|沒有套用|缺少|沒有使用|未使用|missing|does not use|is not annotated|not applied|lacks'

# Phrasings where the finding itself says the thing does not exist yet. Naming a
# symbol that is absent is then the point, not an error: "add a `RetryPolicy`
# wrapper" is a normal suggestion. Only claims that PRESUPPOSE the symbol are
# checkable against the tree.
_MRA_PREMISE_PROPOSAL_RE='新增一(個|支|層|條)|建立一(個|支)|另外(新增|建立)|introduce a|add a new|create a new|define a'

# _review_premise_symbols <body>
# Backticked identifiers a finding names, when — and only when — it claims they
# are established practice. A leading `@` (decorator) is stripped for the search.
_review_premise_symbols() {
  local body="$1"
  printf '%s' "$body" | grep -qiE "$_MRA_PREMISE_CLAIM_RE" || return 0
  printf '%s' "$body" | grep -qiE "$_MRA_PREMISE_PROPOSAL_RE" && return 0
  printf '%s' "$body" \
    | grep -oE '`@?[A-Za-z_][A-Za-z0-9_]{2,}`' \
    | tr -d '`@' \
    | sort -u
}

# _review_symbol_present <repo> <symbol>
# Tracked files only, so a match cannot come from node_modules or build output.
# An unsearchable tree returns "present": absence must be proven, never assumed.
_review_symbol_present() {
  local repo="$1" sym="$2"
  [[ -d "$repo" ]] || return 0
  if git -C "$repo" rev-parse --git-dir >/dev/null 2>&1; then
    git -C "$repo" grep -qIF -- "$sym" >/dev/null 2>&1 && return 0
    # Untracked working-tree files still count as existing code.
    grep -rqIF --exclude-dir=.git -- "$sym" "$repo" >/dev/null 2>&1 && return 0
    return 1
  fi
  grep -rqIF -- "$sym" "$repo" >/dev/null 2>&1 && return 0
  return 1
}

# _review_enforce_premises <review-json> <repo>
# Drop findings whose claimed-existing symbol is nowhere in the tree, and say
# which and why on stderr — a silent drop would be as opaque as the wrong
# finding it removes. Never rewrites the verdict; never touches input it cannot
# parse.
_review_enforce_premises() {
  local review_json="$1" repo="$2"
  # This runs on live reviews and removes findings. If the heuristic ever
  # misfires on a real issue, the operator needs to stop it now, not after a
  # code change and a deploy.
  [[ "${MRA_REVIEW_PREMISE_CHECK:-1}" != "0" ]] || { printf '%s' "$review_json"; return 0; }
  printf '%s' "$review_json" | jq -e . >/dev/null 2>&1 || { printf '%s' "$review_json"; return 0; }
  [[ -d "$repo" ]] || { printf '%s' "$review_json"; return 0; }

  local count idx body sym drop_idx=() missing_note=()
  count=$(printf '%s' "$review_json" | jq '[.comments[]?] | length' 2>/dev/null) || count=0
  [[ "$count" -gt 0 ]] || { printf '%s' "$review_json"; return 0; }

  for ((idx = 0; idx < count; idx++)); do
    body=$(printf '%s' "$review_json" | jq -r ".comments[$idx].body // \"\"" 2>/dev/null)
    [[ -n "$body" ]] || continue
    while IFS= read -r sym; do
      [[ -n "$sym" ]] || continue
      if ! _review_symbol_present "$repo" "$sym"; then
        drop_idx+=("$idx")
        missing_note+=("$(printf '%s' "$review_json" | jq -r ".comments[$idx].path // \"?\"" 2>/dev/null):$sym")
        break
      fi
    done < <(_review_premise_symbols "$body")
  done

  [[ ${#drop_idx[@]} -gt 0 ]] || { printf '%s' "$review_json"; return 0; }

  local drops_json filtered
  drops_json=$(printf '%s\n' "${drop_idx[@]}" | jq -sc 'map(tonumber)') || { printf '%s' "$review_json"; return 0; }
  # `$drop | index(.key)` would evaluate .key against $drop itself, not the
  # entry — bind the entry first.
  filtered=$(printf '%s' "$review_json" | jq -c --argjson drop "$drops_json" '
    .comments = [ .comments | to_entries[] | . as $e
                  | select(($drop | index($e.key)) == null) | $e.value ]
  ' 2>/dev/null) || { printf '%s' "$review_json"; return 0; }

  if declare -F log_warn >/dev/null 2>&1; then
    log_warn "dropped ${#drop_idx[@]} finding(s) claiming an existing convention for a symbol absent from the repository: ${missing_note[*]}" "review" >&2
  else
    printf 'dropped finding(s) citing absent symbol(s): %s\n' "${missing_note[*]}" >&2
  fi
  printf '%s' "$filtered"
}
