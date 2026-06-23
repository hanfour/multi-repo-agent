#!/usr/bin/env bash
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SCRIPT_DIR/lib/colors.sh"
source "$SCRIPT_DIR/lib/config.sh"
source "$SCRIPT_DIR/lib/project-memory.sh"

errors=0
fail() { echo "FAIL: $1"; errors=$((errors+1)); }
MRA_CONFIG=$(mktemp)
write_config() { printf '%s\n' "$1" > "$MRA_CONFIG"; }
VAR=CLAUDE_CODE_ADDITIONAL_DIRECTORIES_CLAUDE_MD

# Case 1: flag ON -> exported = 1
unset $VAR; write_config '{"loadProjectMemory": true}'; apply_project_memory_env
[[ "${!VAR:-unset}" == "1" ]] || fail "ON: expected =1, got ${!VAR:-unset}"

# Case 2: flag OFF -> unset (even if previously set)
export $VAR=1; write_config '{"loadProjectMemory": false}'; apply_project_memory_env
[[ -z "${!VAR+x}" ]] || fail "OFF: expected unset, got ${!VAR:-unset}"

# Case 3: key missing -> default ON
unset $VAR; write_config '{"autoScan": true}'; apply_project_memory_env
[[ "${!VAR:-unset}" == "1" ]] || fail "missing: expected default-ON =1, got ${!VAR:-unset}"

# Case 4: OFF must override a globally-exported var (mra authoritative)
export $VAR=1; write_config '{"loadProjectMemory": false}'; apply_project_memory_env
[[ -z "${!VAR+x}" ]] || fail "OFF-global: mra must unset a globally-exported var"

# Case 5: ordering guard — the call must precede `case "$command"` dispatch
mra_main="$SCRIPT_DIR/bin/mra.sh"
call_line=$(grep -n '^[[:space:]]*apply_project_memory_env' "$mra_main" | head -1 | cut -d: -f1)
case_line=$(grep -n 'case "\$command" in' "$mra_main" | head -1 | cut -d: -f1)
[[ -n "$call_line" && -n "$case_line" && "$call_line" -lt "$case_line" ]] \
  || fail "ordering: call (line ${call_line:-none}) must precede case (line ${case_line:-none})"

# Case 6: config_handle project-memory on/off flips loadProjectMemory
write_config '{}'
config_handle project-memory off >/dev/null 2>&1
[[ "$(config_get loadProjectMemory)" == "false" ]] || fail "config_handle off -> false"
config_handle project-memory on  >/dev/null 2>&1
[[ "$(config_get loadProjectMemory)" == "true" ]]  || fail "config_handle on -> true"
config_handle project-memory bogus >/dev/null 2>&1 && fail "config_handle bogus should return non-zero"

# Case 7: shipped config.json defaults loadProjectMemory ON
[[ "$(config_get loadProjectMemory "$SCRIPT_DIR/config.json")" == "true" ]] \
  || fail "config.json must ship loadProjectMemory: true"

rm -f "$MRA_CONFIG"
if [[ $errors -eq 0 ]]; then echo "PASS: all project-memory tests passed"; else echo "FAIL: $errors tests failed"; exit 1; fi
