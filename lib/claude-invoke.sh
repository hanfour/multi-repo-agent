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
  printf '%s' "$err" | grep -qiE \
    'overloaded|rate.?limit|internal server|service unavailable|tim(e|ed).?out|connection (reset|refused|closed|error)|econnreset|network|temporarily|please try again|(^|[^0-9a-z])(429|5[0-9][0-9])([^0-9a-z]|$)' \
    && return 0
  return 1
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

  while :; do
    # Capture claude's exit code WITHOUT letting `set -e` abort us on a non-zero
    # exit — bin/mra.sh runs with `set -euo pipefail`, and a bare `out=$(claude…)`
    # would exit the whole process the instant claude fails, before `ec=$?` runs,
    # defeating the entire retry design. `if cmd; then` makes the failure
    # non-fatal under errexit so we can inspect ec and retry.
    if [[ "$stream" -eq 1 ]]; then
      if "$bin" "$@" 2>"$errf"; then ec=0; else ec=$?; fi
      out="__streamed__"   # sentinel: stdout went straight to the caller; treat as non-empty
    else
      if out=$("$bin" "$@" 2>"$errf"); then ec=0; else ec=$?; fi
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
      local why; why=$([[ "$ec" -ne 0 ]] && echo "ec=$ec" || echo "empty output")
      log_warn "claude transient failure ($why) — retry $attempt/$max in ${delay}s" "$tag" >&2
      [[ -n "$err" ]] && printf '%s\n' "$err" | tail -3 | sed 's/^/    claude: /' >&2
      sleep "$delay"
      delay=$((delay * 2))
      continue
    fi

    # Give up: surface whatever stderr we captured so the failure is diagnosable,
    # then return claude's output (possibly empty) and exit code to the caller.
    if [[ "$ec" -ne 0 || -z "$out" ]]; then
      if [[ -n "$err" ]]; then
        log_error "claude failed (ec=$ec) after $((attempt + 1)) attempt(s): $(printf '%s' "$err" | tail -5 | tr '\n' ' ')" "$tag" >&2
      else
        log_error "claude failed (ec=$ec) after $((attempt + 1)) attempt(s) with no stderr" "$tag" >&2
      fi
    fi
    # In --stream mode stdout already went to the caller; never echo the sentinel.
    [[ "$stream" -eq 0 ]] && printf '%s' "$out"
    rm -f "$errf"
    return "$ec"
  done
}
