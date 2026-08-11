#!/usr/bin/env bash
# A reply that refutes one of MRA's own findings must reach the next review
# attached to the finding it answers, whole, and must be adjudicated.
#
# Found in production: MRA posted a [HIGH] inline finding resting on a false
# premise. A reviewer replied 9 minutes later with an 838-character rebuttal
# naming the premise and listing three verifications. The review had to be
# dismissed by hand, and a re-run would have produced the identical finding.
#
# Three separate things have to hold for that not to repeat:
#   1. the reply survives the cap (it is the NEWEST item, and the cap kept the
#      oldest 40 while claiming it had dropped the earliest)
#   2. the reply arrives whole and attached to the finding (240-char truncation
#      cut exactly where the evidence started; in_reply_to_id was never read)
#   3. the model must answer it — upholding is fine, silence is not
set -uo pipefail

MRA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$MRA_DIR/lib/colors.sh"
source "$MRA_DIR/lib/review-pr-discussion.sh"
source "$MRA_DIR/lib/review-pr-threads.sh"
source "$MRA_DIR/lib/review-adjudication.sh"

errors=0; pass=0
ok()   { echo "PASS: $1"; pass=$((pass+1)); }
fail() { echo "FAIL: $1"; errors=$((errors+1)); }

# --- fixtures ----------------------------------------------------------------
# The real shape: a prior MRA finding, and a reply pointing at it by id.
REBUTTAL='不改。這個 finding 的前提不成立 — 事件雖然在 document 上派發，但它是 bubbles: true，而規範的傳播路徑中 target 為 Document 的事件會繼續往上傳。三項驗證：(1) 上游函式庫自己就是這樣寫的；(2) 規格書明列唯一例外；(3) 手動實測通過。'
THREAD=$(jq -cn --arg rb "$REBUTTAL" '[
  {id:1, inReplyToId:null, author:"mra-bot", kind:"inline", path:"src/focus.ts", line:22,
   body:"[HIGH] 事件綁在錯誤的目標上，切換分頁後不會刷新。", createdAt:"2026-08-11T01:40:11Z", isPriorReview:true},
  {id:2, inReplyToId:1, author:"ryan", kind:"inline", path:"src/focus.ts", line:22,
   body:$rb, createdAt:"2026-08-11T01:49:59Z", isPriorReview:false},
  {id:3, inReplyToId:null, author:"dana", kind:"comment", path:"", line:null,
   body:"順帶一提，這個 PR 的 migration 已經另外處理了。", createdAt:"2026-08-11T02:00:00Z", isPriorReview:false}
]')

# --- 1. the newest item survives the cap ------------------------------------
# GitHub returns oldest-first, so a rebuttal is always the newest item. The cap
# took .[0:40] — the oldest 40 — and the omission note said the *earlier* items
# had been dropped. Both halves were wrong in the same direction.
MANY=$(jq -cn '[range(0;45) | {author:"u\(.)", loc:"", kind:"comment", body:"item-\(.)"}]')
OUT=$(_review_format_pr_discussion "$MANY")
printf '%s' "$OUT" | grep -qF "item-44" \
  && ok "the newest item survives the cap" \
  || fail "the newest item was dropped — a rebuttal is always the newest item"
printf '%s' "$OUT" | grep -qF "item-0 " \
  && fail "the oldest item survived while the newest was dropped" \
  || ok "the oldest items are the ones dropped"
printf '%s' "$OUT" | grep -q "earlier item" \
  && ok "the omission note says the earlier items were dropped, and they were" \
  || fail "omission note missing or contradicts what was actually dropped"

# --- 2. prior findings are a separate, threaded section ----------------------
SECTION=$(_review_format_prior_findings "$THREAD")
[[ -n "$SECTION" ]] && ok "a prior finding with a reply produces a section" \
                    || fail "no section emitted for a rebutted prior finding"
printf '%s' "$SECTION" | grep -qF "src/focus.ts:22" \
  && ok "the section names the finding's location" || fail "location missing"
printf '%s' "$SECTION" | grep -qF "@ryan" \
  && ok "the reply is attributed" || fail "reply author missing"

# The whole point: the reply must be readable as a reply TO that finding.
finding_line=$(printf '%s\n' "$SECTION" | grep -nF "事件綁在錯誤的目標上" | head -1 | cut -d: -f1)
reply_line=$(printf '%s\n' "$SECTION" | grep -nF "前提不成立" | head -1 | cut -d: -f1)
if [[ -n "$finding_line" && -n "$reply_line" && "$reply_line" -gt "$finding_line" ]]; then
  ok "the reply is rendered under the finding it answers"
else
  fail "the reply is not attached to its finding (finding=$finding_line reply=$reply_line)"
fi

# --- 3. the rebuttal arrives whole ------------------------------------------
# 240 chars cut this one exactly where the evidence began: the claim survived,
# the substantiation did not.
for probe in "三項驗證" "上游函式庫自己就是這樣寫的" "手動實測通過"; do
  printf '%s' "$SECTION" | grep -qF "$probe" \
    && ok "rebuttal keeps its evidence: $probe" \
    || fail "rebuttal truncated before: $probe"
done

# --- 4. no double-reporting between the two sections ------------------------
OTHER=$(_review_format_pr_discussion "$THREAD")
printf '%s' "$OTHER" | grep -qF "前提不成立" \
  && fail "the rebuttal also appears in the generic discussion block" \
  || ok "a reply to a prior finding does not leak into the generic block"
printf '%s' "$OTHER" | grep -qF "migration 已經另外處理" \
  && ok "unrelated discussion still reaches the generic block" \
  || fail "unrelated discussion was lost"

# --- 5. the instruction demands adjudication, not silence -------------------
printf '%s' "$SECTION" | grep -q "ADJUDICATION" \
  && ok "the section states the adjudication contract" || fail "no adjudication contract in the prompt"
printf '%s' "$SECTION" | grep -q "UPHELD" && printf '%s' "$SECTION" | grep -q "WITHDRAWN" \
  && ok "both outcomes are offered (upholding is always available)" \
  || fail "the model must be able to uphold, not only withdraw"

# --- 6. nothing to adjudicate → no section, behaviour unchanged -------------
NOPRIOR=$(jq -cn '[{id:9, inReplyToId:null, author:"dana", kind:"comment", path:"", line:null,
                    body:"just a note", createdAt:"2026-08-11T02:00:00Z", isPriorReview:false}]')
[[ -z "$(_review_format_prior_findings "$NOPRIOR")" ]] \
  && ok "no prior findings → no section" || fail "section emitted with nothing to adjudicate"
# A prior finding nobody answered is not a rebuttal and must not demand one.
UNANSWERED=$(jq -cn '[{id:1, inReplyToId:null, author:"mra-bot", kind:"inline", path:"a.ts", line:3,
                       body:"[LOW] nit", createdAt:"2026-08-11T01:00:00Z", isPriorReview:true}]')
[[ -z "$(_review_rebutted_locations "$UNANSWERED")" ]] \
  && ok "an unanswered prior finding is not a rebuttal" \
  || fail "an unanswered finding must not require adjudication"

# --- 7. which locations carry a rebuttal ------------------------------------
locs=$(_review_rebutted_locations "$THREAD")
[[ "$locs" == "src/focus.ts:22" ]] \
  && ok "the rebutted location is identified" || fail "expected [src/focus.ts:22] got [$locs]"

# MRA replying to its own finding is not somebody rebutting it.
SELFREPLY=$(jq -cn '[
  {id:1, inReplyToId:null, author:"mra-bot", kind:"inline", path:"a.ts", line:3,
   body:"[HIGH] x", createdAt:"2026-08-11T01:00:00Z", isPriorReview:true},
  {id:2, inReplyToId:1, author:"mra-bot", kind:"inline", path:"a.ts", line:3,
   body:"[HIGH] x (restated)", createdAt:"2026-08-11T01:05:00Z", isPriorReview:true}]')
[[ -z "$(_review_rebutted_locations "$SELFREPLY")" ]] \
  && ok "MRA's own follow-up is not a rebuttal of itself" \
  || fail "a self-reply must not count as a rebuttal"

# --- 8. the gate: re-reporting a rebutted finding requires an argument ------
REBUTTED="src/focus.ts:22"

silent='{"status":"CHANGES_REQUESTED","summary":"still broken","comments":[
  {"path":"src/focus.ts","line":22,"severity":"HIGH","body":"事件綁在錯誤的目標上"},
  {"path":"src/other.ts","line":7,"severity":"HIGH","body":"unrelated real issue"}]}'
got=$(_review_enforce_adjudication "$silent" "$REBUTTED")
[[ "$(jq -r '[.comments[] | select(.path=="src/focus.ts")] | length' <<<"$got")" == "0" ]] \
  && ok "a rebutted finding re-reported without an argument is dropped" \
  || fail "the refuted finding survived with no answer to the rebuttal"
[[ "$(jq -r '[.comments[] | select(.path=="src/other.ts")] | length' <<<"$got")" == "1" ]] \
  && ok "an unrelated finding is untouched by the gate" \
  || fail "the gate dropped a finding it had no business touching"

upheld='{"status":"CHANGES_REQUESTED","summary":"ADJUDICATION src/focus.ts:22 UPHELD — the reply cites bubbling, but this listener is registered in the capture phase.","comments":[
  {"path":"src/focus.ts","line":22,"severity":"HIGH","body":"事件綁在錯誤的目標上"}]}'
got=$(_review_enforce_adjudication "$upheld" "$REBUTTED")
[[ "$(jq -r '[.comments[] | select(.path=="src/focus.ts")] | length' <<<"$got")" == "1" ]] \
  && ok "an upheld finding survives — the model may disagree, with an argument" \
  || fail "upholding was refused; the model must be able to hold its ground"

withdrawn='{"status":"APPROVED","summary":"ADJUDICATION src/focus.ts:22 WITHDRAWN — the premise was wrong; the event does bubble to window.","comments":[]}'
got=$(_review_enforce_adjudication "$withdrawn" "$REBUTTED")
[[ "$(jq -r '.summary' <<<"$got")" == *"WITHDRAWN"* ]] \
  && ok "a withdrawal is preserved in the summary where a human reads it" \
  || fail "the withdrawal was lost"

# The gate must never invent or corrupt a result.
[[ "$(jq -r '.status' <<<"$(_review_enforce_adjudication "$silent" "$REBUTTED")")" == "CHANGES_REQUESTED" ]] \
  && ok "the gate does not rewrite the verdict" || fail "the gate changed status"
noloc=$(_review_enforce_adjudication "$silent" "")
[[ "$(jq -r '.comments | length' <<<"$noloc")" == "2" ]] \
  && ok "no rebutted locations → the result passes through untouched" \
  || fail "the gate altered a result with nothing to adjudicate"
bad=$(_review_enforce_adjudication 'not json' "$REBUTTED")
[[ "$bad" == "not json" ]] \
  && ok "malformed input passes through rather than being destroyed" \
  || fail "the gate must not eat a result it cannot parse"

# --- 9. recognising our own prior findings ----------------------------------
# In the integration path MRA posts under the operator's own GitHub account, so
# the author is a human's login and identity alone proves nothing. Both the
# identity AND a content marker have to match.
RAW=$(jq -cn '[
  {id:1, inReplyToId:null, author:"op", kind:"inline", path:"a.ts", line:1,
   body:"[HIGH] a finding MRA wrote", createdAt:"1", isPriorReview:false},
  {id:2, inReplyToId:null, author:"op", kind:"comment", path:"", line:null,
   body:"looks good to me, merging after CI", createdAt:"2", isPriorReview:false},
  {id:3, inReplyToId:null, author:"other", kind:"inline", path:"b.ts", line:2,
   body:"[HIGH] a human imitating the format", createdAt:"3", isPriorReview:false},
  {id:4, inReplyToId:null, author:"op", kind:"review", path:"", line:null,
   body:"summary text\n\nMRA artifact: deadbeef", createdAt:"4", isPriorReview:false}]')
MARKED=$(_review_mark_prior_reviews "$RAW" "op")
chk() { [[ "$(jq -r ".[] | select(.id==$1) | .isPriorReview" <<<"$MARKED")" == "$2" ]] \
        && ok "$3" || fail "$3 (id=$1 expected $2)"; }
chk 1 true  "our own severity-prefixed finding is recognised"
chk 2 false "an ordinary remark from the same account is not a finding"
chk 3 false "another account using the same format is not ours"
chk 4 true  "our own review summary is recognised by its artifact marker"

# Identity unknown (the API call failed) → mark nothing, behave as before.
NONE=$(_review_mark_prior_reviews "$RAW" "")
[[ "$(jq -r '[.[] | select(.isPriorReview == true)] | length' <<<"$NONE")" == "0" ]] \
  && ok "unknown identity marks nothing rather than guessing" \
  || fail "marked comments as ours without knowing who we are"

echo "---"; echo "Passed: $pass"; echo "Failed: $errors"
exit $((errors > 0 ? 1 : 0))
