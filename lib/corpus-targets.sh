#!/usr/bin/env bash
# 外部語料的目標 repo 清單與所屬層。
#
# nestjs 層放了四個生態 repo：nestjs/nest 本身只有約 2,200 則 review comment，
# 但 NestJS 是 Acme PR 量最大的一層（約 720），單靠核心 repo 的語料寫不出
# 有判準的規則。

corpus_layers() {
  printf '%s\n' common nestjs rails react vue
}

corpus_targets() {
  cat <<'EOF'
microsoft/TypeScript	common
nestjs/nest	nestjs
nestjs/typeorm	nestjs
nestjs/swagger	nestjs
prisma/prisma	nestjs
rails/rails	rails
facebook/react	react
TanStack/query	react
vuejs/vue	vue
vuejs/core	vue
EOF
}

# repo 名稱透過 ENVIRON 傳給 awk，不用 -v。awk 的 -v 會先處理反斜線跳脫：
# `rails\/rails` 會被收合成 `rails/rails` 而誤配成功，含換行的值還會讓 awk crash。
corpus_layer_of() {
  local repo="$1"
  corpus_targets \
    | CORPUS_REPO="$repo" awk -F'\t' '$1 == ENVIRON["CORPUS_REPO"] { print $2; found = 1 } END { exit !found }'
}
