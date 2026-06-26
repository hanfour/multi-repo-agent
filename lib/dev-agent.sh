#!/usr/bin/env bash
# Headless write-enabled implement/fix driver for `mra dev`.
# Unlike every other mra claude -p (read-only), this one can Write/Edit/Bash(git)
# so the agent implements and self-commits. Reuses agents/sub-agent.md.

_dev_slugify() {
  local s="$1"
  s=$(printf '%s' "$s" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9' '-' | tr -s '-')
  s="${s#-}"; s="${s%-}"
  printf '%s' "${s:0:50}"
}

# Echo "DONE" or "BLOCKED:<reason>". Explicit sentinel only — never infer from
# prose (the review subsystem abandoned regex-on-prose precisely to kill false greens).
_dev_parse_sentinel() {
  local out="$1" line
  line=$(printf '%s\n' "$out" | grep -oE '===MRA-DEV-DONE===|===MRA-DEV-BLOCKED:[^=]*===' | tail -1 || true)
  if [[ "$line" == *"MRA-DEV-DONE"* ]]; then
    printf 'DONE'
  elif [[ "$line" == *"MRA-DEV-BLOCKED:"* ]]; then
    local reason="${line#*MRA-DEV-BLOCKED:}"; reason="${reason%===}"
    reason=$(printf '%s' "$reason" | sed 's/^ *//;s/ *$//')
    printf 'BLOCKED:%s' "$reason"
  else
    printf 'BLOCKED:no sentinel'
  fi
}

# Dispatch the write-enabled agent. mode=implement|fix. Echoes raw output.
_dev_run_agent() {
  local dir="$1" mode="$2" input="$3"
  local mra_dir; mra_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  local bin="${MRA_DEV_CLAUDE_BIN:-${MRA_CLAUDE_BIN:-claude}}"
  local tools="${MRA_DEV_ALLOWED_TOOLS:-Edit,Write,Read,Grep,Glob,Bash(git:*)}"
  local turns; [[ "$mode" == implement ]] && turns="${MRA_DEV_IMPLEMENT_MAX_TURNS:-45}" || turns="${MRA_DEV_FIX_MAX_TURNS:-20}"
  local lang; lang=$(config_get "outputLanguage" 2>/dev/null); [[ "$lang" == "null" ]] && lang=""
  local verb; [[ "$mode" == implement ]] && verb="Implement this task" || verb="Fix EXACTLY these code-review findings"
  local prompt
  prompt=$(cat <<PROMPT
You are operating headlessly inside ONE repository on a branch that ALREADY EXISTS.
Do NOT create a branch. Do NOT run \`mra test\` or any test suite — there is NO test gate.
Ignore any test-driven-development or Docker test steps in your base instructions.
${verb}:

${input}

Make surgical changes only. Stage and commit your work yourself with git (never \`git add -A\`).
When finished and committed, print on its own line: ===MRA-DEV-DONE===
If you cannot proceed, print: ===MRA-DEV-BLOCKED: <one-line reason>===
${lang:+All prose output in ${lang}; keep the sentinel tokens in English.}
PROMPT
)
  # TASK 0 FINDING: `claude -p` writes relative to its CWD, NOT --add-dir
  # (--add-dir only grants access). cd into the repo so the agent's Write/Edit/git
  # ops land in the target. --setting-sources project bypasses user plugins that break -p.
  ( cd "$dir" && "$bin" -p "$prompt" \
      --append-system-prompt-file "$mra_dir/agents/sub-agent.md" \
      --allowedTools "$tools" \
      --setting-sources project \
      --max-turns "$turns" < /dev/null 2>&1 ) || true
}
