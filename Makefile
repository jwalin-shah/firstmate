.PHONY: fmt lint test clean help ci

help:
	@echo "Available targets:"
	@echo "  make lint       - Run shellcheck"
	@echo "  make fmt        - Format shell scripts (shfmt)"
	@echo "  make test       - Run tests (bats)"
	@echo "  make ci         - Run full CI pipeline"

lint:
	shellcheck -x **/*.sh

fmt:
	shfmt -i 2 -w **/*.sh

fmt-check:
	@if shfmt -i 2 -d **/*.sh | grep -q .; then echo "Format issues found"; exit 1; else echo "✓ Format check passed"; fi

test:
	bats tests/

ci: lint fmt-check test

.DEFAULT_GOAL := help
