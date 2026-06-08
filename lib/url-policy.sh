#!/usr/bin/env bash
# url-policy.sh — outbound URL safety policy (TM-008).
#
# Federation contract fetches and webhook notifications POST/GET to URLs
# from .collab/notify.json or `mra federation subscribe`. Without any
# guardrails an attacker who controls one of those config files can
# point MRA at internal services (cloud metadata, intranet apps, the
# loopback host) and observe responses or trigger side effects.
#
# We do not try to fully solve SSRF here — that would require DNS
# resolution + denylisting + retry hardening. The aim is defense in
# depth:
#
#   1. HTTPS only by default. http://, file://, data:, javascript:, ftp://
#      and other schemes are rejected so that a misconfigured webhook
#      cannot dereference a local file or trigger a clear-text request.
#   2. Hostname literal cannot be loopback / RFC1918 / link-local /
#      0.0.0.0 / IPv6 loopback. Hostnames that are names (not IP
#      literals) are not resolved here — DNS rebinding is out of scope.
#   3. Curl calls go through `safe_curl_args` which sets `--max-time`
#      and `--max-filesize` so a hostile endpoint cannot stream forever
#      or fill the disk.
#
# Overrides for genuinely local development:
#   MRA_ALLOW_LOCAL_ENDPOINTS=1   allow loopback / private IP literals
#   MRA_ALLOW_HTTP=1              allow plaintext http://

# shellcheck shell=bash

# Print an array-style argument list for curl that imposes time + size
# limits. Callers should do:
#   mapfile -t curl_args < <(safe_curl_args)
#   curl "${curl_args[@]}" "$url" ...
safe_curl_args() {
  printf '%s\n' \
    --max-time 30 \
    --max-filesize 5242880
}

# Return 0 if the URL is acceptable under policy, 1 otherwise. Logs the
# reason via log_error so operators can grep for the rejection.
check_safe_url() {
  local url="${1-}"

  _url_log_reject() {
    # Helper: emit a security-log line with reason + url; the caller
    # already wrote the human-readable log_error.
    declare -F log_security_event >/dev/null && \
      log_security_event "url-policy" "reject" "reason=$1" "url=${url:0:256}"
  }

  if [[ -z "$url" ]]; then
    log_error "URL is empty" "url-policy"
    _url_log_reject "empty"
    return 1
  fi

  # Scheme check (TM-008).
  local scheme="${url%%://*}"
  if [[ "$scheme" == "$url" ]]; then
    log_error "URL missing scheme: $url" "url-policy"
    _url_log_reject "missing_scheme"
    return 1
  fi
  case "$scheme" in
    https) ;;
    http)
      if [[ "${MRA_ALLOW_HTTP:-}" != "1" ]]; then
        log_error "http:// is not allowed (set MRA_ALLOW_HTTP=1 to override): $url" "url-policy"
        _url_log_reject "http_not_allowed"
        return 1
      fi
      ;;
    *)
      log_error "scheme '$scheme' is not allowed: $url" "url-policy"
      _url_log_reject "scheme_$scheme"
      return 1
      ;;
  esac

  # Extract host portion. Strip scheme, optional user@, then take up to
  # the first / or ? or end. For IPv6 [::1]/foo the bracket form is
  # preserved.
  local rest="${url#*://}"
  rest="${rest#*@}"
  local host="${rest%%/*}"
  host="${host%%\?*}"
  if [[ "$host" == *":"* && "$host" != "["*"]"* ]]; then
    # host:port for IPv4 / hostname — drop port.
    host="${host%:*}"
  fi
  if [[ -z "$host" ]]; then
    log_error "URL has empty host: $url" "url-policy"
    _url_log_reject "empty_host"
    return 1
  fi

  if [[ "${MRA_ALLOW_LOCAL_ENDPOINTS:-}" != "1" ]]; then
    case "$host" in
      localhost|localhost.localdomain|"[::1]"|"::1"|"0.0.0.0"|"0")
        log_error "loopback host is not allowed (set MRA_ALLOW_LOCAL_ENDPOINTS=1 to override): $host" "url-policy"
        _url_log_reject "loopback_host"
        return 1
        ;;
    esac
    # IPv4 literal ranges. Bash regex on dotted-quad.
    if [[ "$host" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]]; then
      local a="${BASH_REMATCH[1]}" b="${BASH_REMATCH[2]}"
      if (( a == 127 || a == 10 || a == 0 )) \
         || (( a == 169 && b == 254 )) \
         || (( a == 192 && b == 168 )) \
         || (( a == 172 && b >= 16 && b <= 31 )); then
        log_error "private/loopback IPv4 is not allowed: $host (set MRA_ALLOW_LOCAL_ENDPOINTS=1 to override)" "url-policy"
        _url_log_reject "private_ipv4"
        return 1
      fi
    fi
  fi

  return 0
}
