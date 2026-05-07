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

# expand_add_dir_string <out-array-name> <quoted-string>
# Parse a string produced by build_add_dir_string back into a bash array.
# Uses eval, so the input must come from build_add_dir_string /
# append_add_dir_string. As defence in depth we reject anything containing
# shell metacharacters that printf %q output never produces unescaped.
expand_add_dir_string() {
  local -n _out_arr="$1"
  local _str="$2"
  if [[ -z "$_str" ]]; then
    _out_arr=()
    return
  fi
  if [[ "$_str" =~ \;|\&\&|\|\||\`|\$\( ]]; then
    echo "expand_add_dir_string: refusing suspicious input: $_str" >&2
    _out_arr=()
    return 1
  fi
  eval "_out_arr=( $_str )"
}
