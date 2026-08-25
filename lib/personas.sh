#!/usr/bin/env bash
# Persona loader: reads markdown prompt fragments from agents/personas/

# MRA_PERSONAS_DIR 讓呼叫端指向另一份 persona（回測用來指向注入規則後的
# 副本）。設了但指不到目錄時直接失敗，不退回內建的 agents/personas。
#
# 退回預設看起來比較寬容，實際上製造的正是「失敗長得像一個合理的結果」：
# 一輪帶規則的回測把 MRA_PERSONAS_DIR 指向 TMPDIR 底下的注入副本，那個路徑
# 若在幾小時的執行途中被系統清掉（或 label 帶了斜線、環境變數名打錯），每個
# PR 都會改用沒有注入規則的 persona 跑完，summary.json 一切正常，然後被拿去
# 跟基準線比較——比的其實是同一組 persona。警告擋不住這件事：run-backtest.sh
# 把每個 PR 的 stderr 導進各自的 .err 檔，沒有任何東西在解析它。
#
# 空字串視同沒設定（呼叫端刻意的 no-op），不算打錯路徑，不警告也不失敗。
_personas_dir() {
  local mra_dir
  mra_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  local override="${MRA_PERSONAS_DIR:-}"
  if [[ -n "$override" ]]; then
    if [[ -d "$override" ]]; then
      echo "$override"
      return 0
    fi
    echo "PERSONAS_DIR_INVALID：MRA_PERSONAS_DIR=${override} 不是目錄" >&2
    return 1
  fi
  echo "$mra_dir/agents/personas"
}

list_personas() {
  local dir; dir="$(_personas_dir)" || return 1
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
  local dir; dir="$(_personas_dir)" || return 1
  local file; file="$dir/${name}.md"
  if [[ ! -f "$file" ]]; then
    echo "persona not found: $name" >&2
    return 1
  fi
  cat "$file"
}
