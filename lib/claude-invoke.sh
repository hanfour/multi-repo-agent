#!/usr/bin/env bash
# Hardened wrapper around `claude -p` for the review / eval paths.
#
# Why this exists: the review pipeline used to call `claude ... 2>/dev/null`,
# so a transient API failure (overloaded / 5xx / dropped connection) was
# swallowed and surfaced only as an empty stdout — which the debate path then
# read as "agent did not finish" (REVIEW_INCOMPLETE) and the single-pass path
# as "Claude returned empty response". Both forced a manual re-run.
#
# claude_invoke instead:
#   1. Captures stderr (never discards it) and surfaces the tail on final failure.
#   2. Retries transient failures — non-zero exit whose stderr looks retryable,
#      OR a zero-exit-but-empty response — with exponential backoff.
#   3. Passes claude's stdout through unchanged so callers keep capturing the
#      raw JSON / findings text exactly as before.
#
# Tunables:
#   MRA_CLAUDE_MAX_RETRIES  (default 2)      extra attempts after the first
#   MRA_CLAUDE_RETRY_DELAY  (default 3)      initial backoff seconds (doubles each retry)
#   MRA_CLAUDE_BIN          (default claude) binary/mock to invoke (test + override seam)
#   MRA_CLAUDE_TIMEOUT_SECONDS (default 900, 0 disables) per-ATTEMPT time bound

# _mra_bounded_runner <out-array-name> <seconds> <command...>
# Build a command prefix that kills <command> after <seconds>. Shared by the
# claude and codex paths — both had the same bound and the same flaw.
#
# `perl -e 'alarm N; exec ...'` is not enough. It kills the wrapper, but any
# child the wrapper spawned inherits the stdout pipe, so a caller reading
# `out=$(...)` keeps blocking for the whole hang even though the call already
# returned 142. Measured: a 1s bound still cost 20s of waiting. A timeout that
# reports success at bounding while the caller still hangs is worse than none,
# because it looks like it works.
#
# So: fork the command into its own process group and kill the GROUP on alarm.
# alarm survives execve, which is why the bound holds through sandbox-exec.
#
# Emits the command unchanged when the bound is 0, or when perl is missing, or
# when the target is a shell FUNCTION — perl can only exec a real binary, so
# wrapping a function seam would silently bypass it (that sent the test suite at
# the live API once).
_mra_bounded_runner() {
  local -n _mbr_out="$1"; shift
  local secs="$1"; shift
  _mbr_out=("$@")
  [[ "$secs" != "0" ]] || return 0
  command -v perl >/dev/null 2>&1 || return 0
  declare -F "$1" >/dev/null 2>&1 && return 0
  _mbr_out=(perl -e '
    my $t = shift @ARGV;
    my $pid = fork();
    defined $pid or exit 127;
    if ($pid == 0) { setpgrp(0, 0); exec { $ARGV[0] } @ARGV or exit 127; }
    $SIG{ALRM} = sub { kill("KILL", -$pid); waitpid($pid, 0); exit 142; };
    alarm $t;
    waitpid($pid, 0);
    alarm 0;
    my $st = $?;
    exit($st & 127 ? 128 + ($st & 127) : $st >> 8);
  ' "$secs" "$@")
}

# Classify a claude failure as transient (retryable) from its exit code + stderr.
# A zero exit is never a transient *error* (an empty zero-exit result is handled
# separately by claude_invoke). Returns 0 (true) when transient.
#
# The HTTP status codes (429 / 5xx) are matched as standalone tokens: a bare
# status like "503" or "(529)" matches, but a 3-digit run inside a larger number
# ("5000", "line 1500") or one carrying a unit suffix ("512ms", "543rd") does
# NOT — the boundaries require a non-alphanumeric neighbour on each side so a
# genuinely fatal error is not misread as transient. The keyword alternatives
# (overloaded / rate limit / 5xx text / timeout / connection …) catch the common
# transient errors by name regardless; the numeric match is only a backstop.
_claude_is_transient() {
  local ec="$1" err="$2"
  [[ "$ec" -eq 0 ]] && return 1
  # 142 = 128 + SIGALRM: the per-attempt watchdog fired, so the attempt hung.
  # There is nothing in stderr to match on, and retrying is exactly the right
  # response — a hang is the most transient failure there is.
  [[ "$ec" -eq 142 ]] && return 0
  printf '%s' "$err" | grep -qiE \
    'overloaded|rate.?limit|internal server|service unavailable|tim(e|ed).?out|connection (reset|refused|closed|error)|econnreset|network|temporarily|please try again|(^|[^0-9a-z])(429|5[0-9][0-9])([^0-9a-z]|$)' \
    && return 0
  return 1
}

# Per-attempt time bound. Retries answer a call that FAILS; they do nothing for
# one that never returns. Every bound in this codebase lived on the codex side
# (MRA_REVIEW_PROVIDER_TIMEOUT_SECONDS), so a hung claude held a review open
# indefinitely — and if it eventually returned, the late output was accepted as
# a success. alarm survives execve, so the bound holds through any wrapper.
_claude_timeout_secs() {
  local secs="${MRA_CLAUDE_TIMEOUT_SECONDS:-900}"
  if [[ ! "$secs" =~ ^[0-9]+$ ]]; then
    log_warn "invalid MRA_CLAUDE_TIMEOUT_SECONDS='$secs' — using 900" "claude" >&2
    secs=900
  fi
  printf '%s' "$secs"
}

# claude_invoke [--stream] <log_tag> <claude args...>
# Runs `claude "$@"`, echoing its stdout to our stdout. Retries transient
# failures / empty responses up to MRA_CLAUDE_MAX_RETRIES. Returns claude's
# last exit code (stdout may be empty on total failure).
#
# --stream: let claude's stdout go LIVE to the caller's stdout instead of
# buffering it (used by the terminal review path so the operator sees tokens
# stream). Because streamed bytes cannot be un-emitted, --stream does NOT retry
# — a retry after partial output would concatenate a second attempt onto the
# first and corrupt the stream. The transient error is still surfaced; the
# interactive operator re-runs. All the automated/PR paths use the buffered
# (non-stream) mode and keep full retry.
claude_invoke() {
  local stream=0
  if [[ "$1" == "--stream" ]]; then stream=1; shift; fi
  local tag="$1"; shift
  local max="${MRA_CLAUDE_MAX_RETRIES:-2}"
  local delay="${MRA_CLAUDE_RETRY_DELAY:-3}"
  local attempt=0 out ec err errf
  local bin="${MRA_CLAUDE_BIN:-claude}"   # override/mock seam, consistent with the rest of the codebase
  errf=$(mktemp)

  # Bound each attempt, including in --stream (which does not retry, but must
  # still not hang the operator's terminal forever).
  local -a runner=()
  local tsecs; tsecs=$(_claude_timeout_secs)
  _mra_bounded_runner runner "$tsecs" "$bin"

  while :; do
    # Capture claude's exit code WITHOUT letting `set -e` abort us on a non-zero
    # exit — bin/mra.sh runs with `set -euo pipefail`, and a bare `out=$(claude…)`
    # would exit the whole process the instant claude fails, before `ec=$?` runs,
    # defeating the entire retry design. `if cmd; then` makes the failure
    # non-fatal under errexit so we can inspect ec and retry.
    if [[ "$stream" -eq 1 ]]; then
      if "${runner[@]}" "$@" 2>"$errf"; then ec=0; else ec=$?; fi
      out="__streamed__"   # sentinel: stdout went straight to the caller; treat as non-empty
    else
      if out=$("${runner[@]}" "$@" 2>"$errf"); then ec=0; else ec=$?; fi
    fi
    err=$(cat "$errf" 2>/dev/null)

    # Success: non-empty output on a clean exit (in --stream, any clean exit).
    if [[ "$ec" -eq 0 && -n "$out" ]]; then
      [[ "$stream" -eq 0 ]] && printf '%s' "$out"
      rm -f "$errf"
      return 0
    fi

    # Retry (buffered mode only) while attempts remain when EITHER the error is
    # transient (any exit code with a retryable stderr) OR the call "succeeded"
    # (ec=0) but returned nothing — the review paths treat an empty response as a
    # failure anyway. A non-zero exit that is NOT transient (e.g. a bad flag) is a
    # real error and is never retried. --stream never retries (see header).
    if [[ "$stream" -eq 0 && "$attempt" -lt "$max" ]] && \
       { _claude_is_transient "$ec" "$err" || [[ "$ec" -eq 0 && -z "$out" ]]; }; then
      attempt=$((attempt + 1))
      local why
      if [[ "$ec" -eq 142 ]]; then why="hung, killed after ${tsecs}s"
      elif [[ "$ec" -ne 0 ]]; then why="ec=$ec"
      else why="empty output"; fi
      log_warn "claude transient failure ($why) — retry $attempt/$max in ${delay}s" "$tag" >&2
      [[ -n "$err" ]] && printf '%s\n' "$err" | tail -3 | sed 's/^/    claude: /' >&2
      sleep "$delay"
      delay=$((delay * 2))
      continue
    fi

    # Give up: surface whatever stderr we captured so the failure is diagnosable,
    # then return claude's output (possibly empty) and exit code to the caller.
    if [[ "$ec" -ne 0 || -z "$out" ]]; then
      # claude reports some failures on STDOUT and exits non-zero —
      # "Error: Reached max turns (N)" is the common one. Reporting only stderr
      # turned that into "failed (ec=1) with no stderr", which is true and
      # tells the reader nothing; recovering the line the process had already
      # printed took six rounds of probing once. Prefer stderr, fall back to
      # stdout, and only claim silence when both are empty.
      local detail="" detail_src=""
      if [[ -n "$err" ]]; then
        detail=$(printf '%s' "$err" | tail -5 | tr '\n' ' '); detail_src="stderr"
      elif [[ "$stream" -eq 0 && -n "$out" ]]; then
        detail=$(printf '%s' "$out" | tail -5 | tr '\n' ' '); detail_src="stdout"
      fi
      if [[ -n "$detail" ]]; then
        log_error "claude failed (ec=$ec) after $((attempt + 1)) attempt(s) [$detail_src]: $detail" "$tag" >&2
      else
        log_error "claude failed (ec=$ec) after $((attempt + 1)) attempt(s) with no stderr or stdout" "$tag" >&2
      fi
    fi
    # In --stream mode stdout already went to the caller; never echo the sentinel.
    [[ "$stream" -eq 0 ]] && printf '%s' "$out"
    rm -f "$errf"
    return "$ec"
  done
}
