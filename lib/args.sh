#!/usr/bin/env bash
# args.sh — argument-safe path handling for `--add-dir` plumbing.
#
# Why: many lib/*.sh helpers historically built `--add-dir=$dir` strings or
# `--add-dir $dir` strings and then word-split them unquoted into the claude
# command line. Paths containing spaces or shell metacharacters silently
# broke. Centralizing the quoting here keeps callers honest.

# build_add_dir_string <path...> -> emits "--add-dir <q-escaped path>" pairs
# joined by spaces. Empty arguments are skipped. Output is safe to expand
# back into an array via `expand_add_dir_string`.
build_add_dir_string() {
  local out="" d
  for d in "$@"; do
    [[ -z "$d" ]] && continue
    if [[ -n "$out" ]]; then
      out="$out "
    fi
    out+="$(printf -- '--add-dir %q' "$d")"
  done
  printf '%s' "$out"
}

# append_add_dir_string <var-name> <path>
# Mutates the named string variable in place by appending one quoted pair.
append_add_dir_string() {
  local _var="$1"; local _path="$2"
  [[ -z "$_path" ]] && return
  local _piece
  _piece="$(printf -- '--add-dir %q' "$_path")"
  if [[ -n "${!_var}" ]]; then
    printf -v "$_var" '%s %s' "${!_var}" "$_piece"
  else
    printf -v "$_var" '%s' "$_piece"
  fi
}

# Characters that can cause expansion, substitution, redirection or word
# splitting when a string is evaluated as bash source. printf %q renders every
# one of them as a backslash escape, so once escape pairs are collapsed none
# may legitimately remain.
_MRA_ADD_DIR_OPERAND='[^][(){}<>|&;$`\\'"'"'"*?~!#[:space:]]+'
_MRA_ADD_DIR_RE="^--add-dir ${_MRA_ADD_DIR_OPERAND}( --add-dir ${_MRA_ADD_DIR_OPERAND})*$"

# expand_add_dir_string <out-array-name> <quoted-string>
# Parse a string produced by build_add_dir_string back into a bash array.
# Uses eval, so the input is validated against an allowlist first: collapse the
# backslash escape pairs printf %q emits to a placeholder, then require what
# remains to be nothing but `--add-dir <plain path>` pairs. Anything else fails
# closed. The placeholder (rather than deletion) keeps an operand that is
# entirely escaped -- a path like `~` renders as `\~` -- from collapsing to the
# empty string and being refused.
#
# This replaced a blacklist of `;`, `&&`, `||`, backtick and `$(`, which was
# wrong in both directions (GHSA-8m99-vc82-25m4). Too loose: it never saw
# process substitution — `<(cmd)` EXECUTED cmd — nor parameter expansion,
# tilde expansion or globbing, all of which it let through. Too tight: it
# tested the ESCAPED string, so a legitimate path containing a backtick or a
# semicolon arrived as `/a\;b` and was refused. Enumerating dangerous
# metacharacters cannot be made complete; describing the safe shape can.
#
# Paths containing control characters are rejected rather than evaluated:
# printf %q renders those as `$'...'`, which this allowlist does not admit.
expand_add_dir_string() {
  local -n _out_arr="$1"
  local _str="$2"
  _out_arr=()
  [[ -z "$_str" ]] && return 0
  local _bare
  _bare=$(printf '%s' "$_str" | sed 's/\\./_/g')
  if [[ ! "$_bare" =~ $_MRA_ADD_DIR_RE ]]; then
    echo "expand_add_dir_string: refusing input that is not printf %q --add-dir pairs: $_str" >&2
    return 1
  fi
  eval "_out_arr=( $_str )"
}
