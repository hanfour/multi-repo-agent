#!/usr/bin/env bash
# Every third-party GitHub Action must be pinned to a full commit SHA.
#
# Tags are mutable: the upstream owner can repoint v4 at any time, so a tag
# reference does not describe the code CI will execute. deploy-site.yml holds
# pages:write and id-token:write, and repo-tests.yml runs on pull_request —
# both are places where silently-changed third-party code matters (#36).
#
# Local composite actions (./actions/...) are in-tree and need no pin.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

errors=0; pass=0
ok()   { echo "PASS: $1"; pass=$((pass+1)); }
fail() { echo "FAIL: $1"; errors=$((errors+1)); }

mapfile -t refs < <(
  grep -rhoE '^[[:space:]]*-?[[:space:]]*uses:[[:space:]]*[^[:space:]]+' \
    "$SCRIPT_DIR/.github/workflows" "$SCRIPT_DIR/actions" 2>/dev/null |
    sed -E 's/.*uses:[[:space:]]*//' | sort -u
)

[[ ${#refs[@]} -gt 0 ]] && ok "found ${#refs[@]} action reference(s)" \
                        || fail "no action references found — check the scan paths"

for ref in "${refs[@]}"; do
  case "$ref" in
    ./*) ok "local action not pinned: $ref" ; continue ;;
  esac
  version="${ref##*@}"
  if [[ "$version" =~ ^[0-9a-f]{40}$ ]]; then
    ok "pinned to a SHA: $ref"
  else
    fail "mutable ref (pin to a 40-char commit SHA): $ref"
  fi
done

# A pin is only maintainable if something bumps it.
dependabot="$SCRIPT_DIR/.github/dependabot.yml"
if [[ -f "$dependabot" ]] && grep -q 'github-actions' "$dependabot"; then
  ok "dependabot tracks the github-actions ecosystem"
else
  fail "no dependabot config for github-actions — pins will rot"
fi

# --- every action must be exercised by a workflow that runs on pull_request --
# A Dependabot bump is reviewed against a green check. If no pull_request-
# triggered workflow uses the action being bumped, that green says nothing about
# it and the first real test is against main. That is what happened to the three
# GitHub Pages actions: they appear only in deploy-site.yml, which used to run on
# push only.
pr_workflows=()
for wf in "$SCRIPT_DIR"/.github/workflows/*.yml; do
  # `pull_request:` as a trigger key, not a mention inside a run block.
  if awk '/^on:/{i=1;next} /^[a-z]/{i=0} i && /^  pull_request:?$/{found=1} END{exit !found}' "$wf"; then
    pr_workflows+=("$wf")
  fi
done

[[ ${#pr_workflows[@]} -gt 0 ]] && ok "found ${#pr_workflows[@]} pull_request-triggered workflow(s)" \
                                || fail "no workflow runs on pull_request — no bump can be validated"

unexercised=()
for ref in "${refs[@]}"; do
  case "$ref" in ./*) continue ;; esac
  action="${ref%@*}"
  covered=false
  for wf in "${pr_workflows[@]}"; do
    grep -q "$action@" "$wf" && { covered=true; break; }
  done
  $covered || unexercised+=("$action")
done

if [[ ${#unexercised[@]} -eq 0 ]]; then
  ok "every third-party action is exercised on pull_request"
else
  fail "bumping these would be reviewed against a green check that never ran them: ${unexercised[*]}"
fi

echo "---"; echo "Passed: $pass"; echo "Failed: $errors"
exit $((errors > 0 ? 1 : 0))
