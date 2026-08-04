.PHONY: test test-repeat build lint lint-all mcp-install help clean

MCP_INSTALLED := mcp-server/node_modules/.package-lock.json

help:
	@echo "make test         Run all shell tests + mcp-server tests"
	@echo "make test-repeat  Run the suite REPEAT times (default 20) to surface flaky tests"
	@echo "make build        Build mcp-server (tsc) — incremental"
	@echo "make mcp-install  Install mcp-server node deps (only when stale)"
	@echo "make lint         Run shellcheck at the CI blocking severity (-S error)"
	@echo "make lint-all     Run shellcheck including warnings (non-blocking backlog)"
	@echo "make clean        Remove mcp-server build artifacts"

# Depends on mcp-install so a fresh checkout runs the full suite instead of
# hitting test.sh's "deps missing" failure. The sentinel below keeps this a
# no-op once deps are current.
test: mcp-install
	bash test.sh

# Surfaces flaky tests without waiting for one to appear by chance (#52).
# Stops at the first failure so .mra-test-logs/ describes THAT run rather than
# being overwritten by the next one.
REPEAT ?= 20
test-repeat: mcp-install
	@for i in $$(seq 1 $(REPEAT)); do \
		printf '=== run %s/%s ===\n' "$$i" "$(REPEAT)"; \
		bash test.sh >/dev/null 2>&1 || { \
			echo "FAILED on run $$i — logs in .mra-test-logs/"; \
			ls .mra-test-logs/ 2>/dev/null; exit 1; }; \
	done; \
	echo "$(REPEAT) runs, no failures"

# Install only when package.json / package-lock.json changes — npm writes
# .package-lock.json under node_modules whenever it (re)installs, so we use
# it as a sentinel and let make's mtime check skip needless reinstalls.
$(MCP_INSTALLED): mcp-server/package.json mcp-server/package-lock.json
	npm --prefix mcp-server install

mcp-install: $(MCP_INSTALLED)

build: mcp-install
	npm --prefix mcp-server run build

# Gates on -S error, the same severity CI blocks on (.github/workflows/
# repo-tests.yml). These two drifted once — lint ran at -S warning and was
# permanently red while CI was green — and a developer command that always
# fails is a developer command nobody reads. tests/test_lint_gate.sh keeps
# them in step. Use `make lint-all` for the warning backlog.
lint:
	@if command -v shellcheck >/dev/null 2>&1; then \
		shellcheck -S error lib/*.sh bin/*.sh tests/*.sh test.sh; \
	else \
		echo "shellcheck not installed (brew install shellcheck) — skipping"; \
	fi

lint-all:
	@if command -v shellcheck >/dev/null 2>&1; then \
		shellcheck -S warning lib/*.sh bin/*.sh tests/*.sh test.sh; \
	else \
		echo "shellcheck not installed (brew install shellcheck) — skipping"; \
	fi

clean:
	rm -rf mcp-server/dist
