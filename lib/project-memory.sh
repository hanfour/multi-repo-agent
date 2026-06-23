#!/usr/bin/env bash
# Project-memory loading switch.
#
# Controls whether each --add-dir project's NATIVE instruction files
# (CLAUDE.md, AGENTS.md, .claude/rules/) load into the claude CLI mra
# launches. Governed ONLY by those files — NOT skills (already auto-load
# via --add-dir) and NOT settings.local.json.
#
# Implemented with claude's CLAUDE_CODE_ADDITIONAL_DIRECTORIES_CLAUDE_MD
# env var, exported once at the top of main() so every child claude
# process (interactive launch, headless `claude -p`, pkb generators)
# inherits it. Depends on config_get (lib/config.sh).
apply_project_memory_env() {
  local enabled
  enabled=$(config_get "loadProjectMemory" 2>/dev/null)
  # Default ON: only an explicit "false" disables. A missing key (jq null),
  # "true", or empty all enable. unset (not skip) on OFF so an OFF config is
  # authoritative even over a var the user exported globally in their shell.
  if [[ "$enabled" == "false" ]]; then
    unset CLAUDE_CODE_ADDITIONAL_DIRECTORIES_CLAUDE_MD
  else
    export CLAUDE_CODE_ADDITIONAL_DIRECTORIES_CLAUDE_MD=1
  fi
}
