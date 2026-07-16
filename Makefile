.PHONY: test build lint mcp-install help clean

MCP_INSTALLED := mcp-server/node_modules/.package-lock.json

help:
	@echo "make test         Run all shell tests + mcp-server tests"
	@echo "make build        Build mcp-server (tsc) — incremental"
	@echo "make mcp-install  Install mcp-server node deps (only when stale)"
	@echo "make lint         Run shellcheck over lib/, bin/, scanners/, tests/"
	@echo "make clean        Remove mcp-server build artifacts"

test:
	bash test.sh

# Install only when package.json / package-lock.json changes — npm writes
# .package-lock.json under node_modules whenever it (re)installs, so we use
# it as a sentinel and let make's mtime check skip needless reinstalls.
$(MCP_INSTALLED): mcp-server/package.json mcp-server/package-lock.json
	npm --prefix mcp-server install

mcp-install: $(MCP_INSTALLED)

build: mcp-install
	npm --prefix mcp-server run build

lint:
	@if command -v shellcheck >/dev/null 2>&1; then \
		shellcheck -S warning lib/*.sh bin/*.sh tests/*.sh test.sh; \
	else \
		echo "shellcheck not installed (brew install shellcheck) — skipping"; \
	fi

clean:
	rm -rf mcp-server/dist
