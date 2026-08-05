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
  # Both branches run through the review path's isolation. The plan path sends
  # a prompt to the same models over the same credentials; there was no reason
  # for it to be the unprotected one, and it silently was: GH_TOKEN readable,
  # ~/.ssh and ~/.codex readable, no time bound, stdin inherited.
  case "$provider" in
    claude)
      local _ad=()
      expand_add_dir_string _ad "$add_dirs"
      # </dev/null for the same reason as the codex branch: an inherited
      # non-tty stdin the caller never closes is a freeze waiting to happen.
      MRA_REVIEW_AUTH_PROVIDER=claude _review_without_github_credentials \
        "${MRA_CLAUDE_BIN:-claude}" -p "$prompt" \
        "${_ad[@]}" \
        --model "$model" \
        --max-turns "$max_turns" \
        --disallowedTools "Write,Edit,NotebookEdit" \
        --setting-sources "project" </dev/null
      ;;
    codex)
      # model / add_dirs / max_turns intentionally unused — codex exec takes none of them
      #
      # Sandboxing lands on exactly one layer, same rule as the review path:
      # codex applies a deny-default profile per command, which macOS refuses
      # inside mra's sandbox-exec, so where mra wraps it codex must stand down.
      local -a _sandbox_args=(-s read-only)
      if command -v sandbox-exec >/dev/null 2>&1; then
        _sandbox_args=(--dangerously-bypass-approvals-and-sandbox)
      fi
      # Read the operator's real config BEFORE the isolation redirects
      # CODEX_HOME. Without these the isolated codex has no config.toml, falls
      # back to api.openai.com, and every call returns 401 with a key that is
      # valid for the relay it never reached.
      local -a _provider_overrides=()
      _review_codex_provider_overrides _provider_overrides

      local -a _cmd=("${MRA_CODEX_BIN:-codex}")
      local _secs
      _secs=$(_review_codex_watchdog_secs 2>/dev/null || echo 900)
      if [[ "$_secs" != "0" ]] && command -v perl >/dev/null 2>&1; then
        # alarm survives execve, including through sandbox-exec (issue #18).
        _cmd=(perl -e 'my $t = shift @ARGV; alarm $t; exec { $ARGV[0] } @ARGV or exit 127;' "$_secs" "${_cmd[@]}")
      fi
      (
        cd "$project_dir" || return 1
        MRA_REVIEW_SANDBOX_WRITABLE_ROOTS="${TMPDIR:-/tmp}" \
        MRA_REVIEW_AUTH_PROVIDER=codex _review_without_github_credentials \
          "${_cmd[@]}" exec "${_sandbox_args[@]}" "${_provider_overrides[@]}" "$prompt" </dev/null
      )
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
