# mra branch

Manage the same feature branch across many repos, then open and merge PRs together — all in dependency order.

```bash
mra branch status                 # which repos need attention
mra branch new feature/login      # create the branch everywhere
mra branch switch feature/login   # switch every repo to it
mra branch pr                     # push branches + open PRs (deps first)
mra branch merge --wait-ci        # merge each PR once CI is green
```

## status

Cross-repo overview of where every branch stands (ahead/behind/dirty/PR state).

```bash
mra branch status              # default: only repos needing attention
mra branch status --all        # every repo
mra branch status --fetch      # fetch remotes first for accurate ahead/behind
mra branch status --json       # machine-readable array of every repo
```

## new / switch

```bash
mra branch new <name>          # create <name> from each repo's base branch
mra branch switch <name>       # checkout <name> in every repo that has it
```

## pr

Push feature branches and open PRs across repos, in dependency order so downstream PRs can reference upstream ones.

```bash
mra branch pr                          # all repos with commits ahead
mra branch pr --base develop           # target a non-default base
mra branch pr --dry-run                # preview without pushing
mra branch pr my-api frontend-app      # only this subset
```

## merge

Merge open PRs, gated on mergeable state + CI. Runs in dependency order.

```bash
mra branch merge                               # merge every ready PR
mra branch merge --strategy squash             # merge | squash | rebase
mra branch merge --wait-ci                     # poll CI, merge each PR when green
mra branch merge --wait-ci --ci-timeout 1200   # give CI up to 20 min
mra branch merge --delete-branch               # delete the remote branch after merge
mra branch merge my-api                        # only this subset
```

| Flag | Effect |
|------|--------|
| `--strategy merge\|squash\|rebase` | Merge method (default `merge`) |
| `--wait-ci` | Poll each PR's checks and merge only once green |
| `--ci-timeout <sec>` | Max seconds to wait for CI (requires `--wait-ci`) |
| `--delete-branch` | Delete the remote branch after a successful merge |
| `--dry-run` | Report what would merge without merging |
| `[repos…]` | Restrict to a subset of repos |
