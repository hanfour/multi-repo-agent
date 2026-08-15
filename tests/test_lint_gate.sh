#!/usr/bin/env bash
# 本地 lint gate 跟 CI 的 blocking gate 要在「嚴重度」跟「涵蓋的檔案」兩件事上
# 保持一致。
#
# 這兩邊已經飄過兩次：第一次是嚴重度（#35 —— make lint 跑 `-S warning`，49 個
# 發現讓它永遠是紅的，CI 卻只 block `-S error`）；第二次是涵蓋範圍（scripts/*.sh
# 完全不在兩邊任何一個 gate 裡，`make lint` 回報綠燈從來沒有替這條分支最大的
# 檔案背書過）。原本只驗嚴重度的斷言抓不到第二種飄移，所以這裡再加一組比對
# 兩邊各自宣告要 gate 的檔案 glob「集合」，而不只是嚴重度數字。
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CI="$SCRIPT_DIR/.github/workflows/repo-tests.yml"

errors=0; pass=0
ok()   { echo "PASS: $1"; pass=$((pass+1)); }
fail() { echo "FAIL: $1"; errors=$((errors+1)); }

# CI 真正會 block 的那一行：跳過被 continue-on-error 蓋住的那次 shellcheck。
ci_line=$(awk '
  /continue-on-error:[[:space:]]*true/ { skip = 1 }
  /shellcheck -S/ {
    if (skip) { skip = 0; next }
    print; exit
  }
' "$CI")

# make lint 目標裡的 shellcheck 那一行。
make_line=$(awk '
  /^lint:/       { in_target = 1; next }
  /^[a-z-]+:/    { in_target = 0 }
  in_target && /shellcheck -S/ { print; exit }
' "$SCRIPT_DIR/Makefile")

# 嚴重度：從抓到的那一行裡取 `-S <word>`。
ci_gate=$(printf '%s\n' "$ci_line" | grep -oE -- '-S [a-z]+' | head -1 | cut -d' ' -f2)
make_gate=$(printf '%s\n' "$make_line" | grep -oE -- '-S [a-z]+' | head -1 | cut -d' ' -f2)

[[ -n "$ci_gate" ]]   && ok "found the CI blocking severity ($ci_gate)" \
                      || fail "could not read the CI blocking severity from $CI"
[[ -n "$make_gate" ]] && ok "found the make lint severity ($make_gate)" \
                      || fail "could not read the make lint severity from Makefile"

if [[ "$ci_gate" == "$make_gate" ]]; then
  ok "make lint and the CI gate agree on severity"
else
  fail "gate drift — CI blocks on '-S $ci_gate' but make lint uses '-S $make_gate'"
fi

# 檔案清單：把 "shellcheck -S <severity> " 前綴去掉；Makefile 那行還要再去掉
# recipe 續行用的 "; \" 結尾，剩下的就是各自宣告要 gate 的 glob 清單。
ci_files_raw=$(printf '%s\n' "$ci_line" \
  | sed -E 's/^.*shellcheck[[:space:]]+-S[[:space:]]+[a-z]+[[:space:]]*//')
make_files_raw=$(printf '%s\n' "$make_line" \
  | sed -E 's/^.*shellcheck[[:space:]]+-S[[:space:]]+[a-z]+[[:space:]]*//; s/;[[:space:]]*\\[[:space:]]*$//')

read -ra ci_files_arr <<< "$ci_files_raw"
read -ra make_files_arr <<< "$make_files_raw"

ci_files_sorted="$(printf '%s\n' "${ci_files_arr[@]}" | sort)"
make_files_sorted="$(printf '%s\n' "${make_files_arr[@]}" | sort)"

if [[ -n "$ci_files_sorted" && -n "$make_files_sorted" ]]; then
  ok "found file globs on both sides (CI: ${#ci_files_arr[@]}, make: ${#make_files_arr[@]})"
else
  fail "could not read the file globs from one side (CI raw: [$ci_files_raw], make raw: [$make_files_raw])"
fi

if [[ "$ci_files_sorted" == "$make_files_sorted" ]]; then
  ok "make lint and the CI gate cover the same file set"
else
  fail "file-set drift — CI covers [${ci_files_arr[*]}] but make lint covers [${make_files_arr[*]}]"
fi

# gate 本身要是乾淨的，不然就不算是個 gate。scripts/*.sh 要跟 Makefile／CI
# 現在宣告的清單一致，理由見上面兩段。
if command -v shellcheck >/dev/null 2>&1; then
  if (cd "$SCRIPT_DIR" && shellcheck -S "${make_gate:-error}" lib/*.sh bin/*.sh scripts/*.sh tests/*.sh test.sh >/dev/null 2>&1); then
    ok "the tree is clean at the gate severity"
  else
    fail "make lint would fail on a clean checkout"
  fi
else
  ok "shellcheck absent — gate cleanliness not checked here"
fi

echo "---"; echo "Passed: $pass"; echo "Failed: $errors"
exit $((errors > 0 ? 1 : 0))
