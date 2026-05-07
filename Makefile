.PHONY: test build lint mcp-install help

help:
	@echo "make test         Run all shell tests + mcp-server tests"
	@echo "make build        Build mcp-server (tsc)"
	@echo "make mcp-install  Install mcp-server node deps"
	@echo "make lint         Run shellcheck over lib/, bin/, scanners/, tests/"

test:
	bash test.sh

mcp-install:
	npm --prefix mcp-server install

build: mcp-install
	npm --prefix mcp-server run build

lint:
	@if command -v shellcheck >/dev/null 2>&1; then \
		shellcheck -S warning lib/*.sh bin/*.sh scanners/*.sh tests/*.sh test.sh; \
	else \
		echo "shellcheck not installed (brew install shellcheck) — skipping"; \
	fi
