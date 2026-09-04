#!/usr/bin/env bash
set -euo pipefail

# headless claude 帶著自己的內建工具，其中有些會把結果吞進工具呼叫，讓最終
# 文字只剩摘要。ReportFindings 就是這樣：persona 用它回報時，
# review_call_model 只拿得到「共找到 5 個問題（2 個 CRITICAL…）」這一句，
# finding 本體全部收不到，synthesize 於是看不到那幾條（2026-09-04 的回測在
# 232 次 persona 呼叫裡撞到 3 次，其中一次丟掉 2 條 CRITICAL）。
#
# 這個檔案守兩件事：清單本身要禁掉這些工具，以及清單只有一份。之前十個呼叫
# 點各自硬寫同一串字面量，少改一處就是一個不設防的呼叫點，而那種漏在最終
# JSON 上完全看不出來。

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SCRIPT_DIR/lib/claude-invoke.sh"

errors=0
pass(){ echo "PASS: $1"; }
fail(){ echo "FAIL: $1"; errors=$((errors+1)); }

# --- 1. 清單本身 ---------------------------------------------------------

if [[ -n "${MRA_CLAUDE_DISALLOWED_TOOLS:-}" ]]; then
  pass "MRA_CLAUDE_DISALLOWED_TOOLS is defined"
else
  fail "MRA_CLAUDE_DISALLOWED_TOOLS is not defined by lib/claude-invoke.sh"
fi

for tool in Write Edit NotebookEdit ReportFindings; do
  case ",${MRA_CLAUDE_DISALLOWED_TOOLS:-}," in
    *",$tool,"*) pass "disallowed list covers $tool" ;;
    *) fail "disallowed list is missing $tool: '${MRA_CLAUDE_DISALLOWED_TOOLS:-}'" ;;
  esac
done

# --- 2. 清單只有一份 -----------------------------------------------------

# 任何 --disallowedTools 的參數都要來自那個變數，不能是硬寫的工具名。
literals=$(grep -rn -- "--disallowedTools" "$SCRIPT_DIR/lib" "$SCRIPT_DIR/scripts" "$SCRIPT_DIR/bin" \
  2>/dev/null | grep -v 'MRA_CLAUDE_DISALLOWED_TOOLS' || true)
if [[ -z "$literals" ]]; then
  pass "no call site hardcodes its own disallowed-tools list"
else
  fail "call sites still hardcode the list:"$'\n'"$literals"
fi

# 至少要有一個呼叫點真的用到它，不然上面那條檢查會在全部刪光時也通過。
users=$( { grep -rl -- 'MRA_CLAUDE_DISALLOWED_TOOLS' "$SCRIPT_DIR/lib" "$SCRIPT_DIR/scripts" 2>/dev/null || true; } | wc -l | tr -d ' ')
if [[ "$users" -ge 5 ]]; then
  pass "the shared list is used by $users files"
else
  fail "only $users file(s) reference MRA_CLAUDE_DISALLOWED_TOOLS — expected the call sites to use it"
fi

# --- 3. review 的 claude 呼叫真的帶上去 ----------------------------------

export MRA_REVIEW_SENTINEL_TOKEN="MRA-REVIEW-COMPLETE"
unset GH_TOKEN GITHUB_TOKEN OPENAI_API_KEY

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export MRA_CONFIG="$TMP/config.json"
echo '{"configVersion":2}' > "$MRA_CONFIG"

# review_call_model 的 claude 分支會擋掉沒有憑證的呼叫，所以給它一份假的。
FAKE_HOME="$TMP/home"
mkdir -p "$FAKE_HOME/.claude"
printf '{"claudeAiOauth":{"accessToken":"test-only-token"}}\n' > "$FAKE_HOME/.claude/.credentials.json"
export HOME="$FAKE_HOME"

source "$SCRIPT_DIR/lib/colors.sh"
source "$SCRIPT_DIR/lib/review-verdict.sh"
source "$SCRIPT_DIR/lib/config.sh"
source "$SCRIPT_DIR/lib/args.sh"
source "$SCRIPT_DIR/lib/review-provider.sh"

BIN="$TMP/bin"; mkdir -p "$BIN" "$TMP/project"
REC="$TMP/rec"
cat > "$BIN/claude" <<'STUB'
#!/usr/bin/env bash
echo "claude: $*" >> "$REC"
echo "<claude-output>"
STUB
chmod +x "$BIN/claude"
export REC

out=$(MRA_CLAUDE_BIN="$BIN/claude" review_call_model review claude "PROMPT" "" "$TMP/project" "" 5 "") || true
[[ "$out" == "<claude-output>" ]] || fail "stub did not run: $out"
rec=$(cat "$REC")
case "$rec" in
  *"--disallowedTools"*"ReportFindings"*) pass "review claude call disallows ReportFindings" ;;
  *) fail "review claude call is missing ReportFindings: $rec" ;;
esac

[[ "$errors" -eq 0 ]] && echo "All disallowed-tools tests passed" || echo "$errors test(s) failed"
exit "$errors"
