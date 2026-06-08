#!/usr/bin/env bash
# Model provider abstraction for mra: dispatch one prompt to claude or codex.
# Depends on: expand_add_dir_string (lib/args.sh), log_error (lib/colors.sh).
# Binary names are env-overridable (MRA_CLAUDE_BIN / MRA_CODEX_BIN) for tests.

# Run one prompt against a provider, printing the model's response to stdout.
# Args: provider prompt model project_dir add_dirs max_turns
#   claude -> existing council invocation (edit tools disabled; --max-turns parameterized
#             so experts use 6 and the synthesizer uses 4).
#   codex  -> `codex exec -s read-only` (read-only sandbox), cwd = project_dir so it sees the repo.
#             (codex has no turn limit; max_turns applies to the claude branch only.)
call_model() {
  local provider="$1" prompt="$2" model="$3" project_dir="$4" add_dirs="$5" max_turns="${6:-6}"
  case "$provider" in
    claude)
      local _ad=()
      expand_add_dir_string _ad "$add_dirs"
      "${MRA_CLAUDE_BIN:-claude}" -p "$prompt" \
        "${_ad[@]}" \
        --model "$model" \
        --max-turns "$max_turns" \
        --disallowedTools "Write,Edit,NotebookEdit" \
        --setting-sources "project"
      ;;
    codex)
      # model / add_dirs / max_turns intentionally unused — codex exec takes none of them
      ( cd "$project_dir" && "${MRA_CODEX_BIN:-codex}" exec -s read-only "$prompt" )
      ;;
    *)
      log_error "call_model: unknown provider '$provider'" "plan" >&2; return 2
      ;;
  esac
}

# Preflight gate for `mra plan --dual`: is the codex CLI available?
ensure_codex_available() {
  command -v "${MRA_CODEX_BIN:-codex}" >/dev/null 2>&1
}
