#!/usr/bin/env bash
# Persona loader: reads markdown prompt fragments from agents/personas/

# MRA_PERSONAS_DIR 讓呼叫端指向另一份 persona（回測用來指向注入規則後的
# 副本）。指到不存在的目錄時退回預設並印警告，不是直接用下去：打錯路徑會
# 讓整輪回測跑在沒有規則的 persona 上，而且看起來像正常執行——那正是這個
# 專案一路在防的「失敗長得像一個合理的結果」。
_personas_dir() {
  local mra_dir
  mra_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  local override="${MRA_PERSONAS_DIR:-}"
  if [[ -n "$override" ]]; then
    if [[ -d "$override" ]]; then
      echo "$override"
      return 0
    fi
    echo "PERSONAS_DIR_INVALID：MRA_PERSONAS_DIR=${override} 不是目錄，改用預設" >&2
  fi
  echo "$mra_dir/agents/personas"
}

list_personas() {
  local dir; dir="$(_personas_dir)"
  [[ -d "$dir" ]] || return 0
  local f
  for f in "$dir"/*.md; do
    [[ -f "$f" ]] || continue
    local name; name="$(basename "$f" .md)"
    [[ "$name" == "README" ]] && continue
    echo "$name"
  done
}

load_persona() {
  local name="$1"
  local file; file="$(_personas_dir)/${name}.md"
  if [[ ! -f "$file" ]]; then
    echo "persona not found: $name" >&2
    return 1
  fi
  cat "$file"
}
