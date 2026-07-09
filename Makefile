# Firstmate Makefile

.PHONY: all fmt lint test clean help ci build

help:
	@echo "Available targets:"
	@echo "  make            - Build Go binaries"
	@echo "  make lint       - Run shellcheck"
	@echo "  make fmt        - Format shell scripts (shfmt)"
	@echo "  make test       - Run tests (bash)"
	@echo "  make ci         - Run full CI pipeline"
	@echo "  make build      - Build Go helper binaries"

build:
	cd bin && go build -o mm-event-sub mm-event-sub.go
	cd bin && go build -o fm-kqueue-watch fm-kqueue-watch.go

all: build

lint:
	shellcheck -x bin/*.sh

fmt:
	shfmt -i 2 -w bin/*.sh

fmt-check:
	@if shfmt -i 2 -d bin/*.sh | grep -q .; then echo "Format issues found"; exit 1; else echo "✓ Format check passed"; fi

test: build
	rc=0
	for t in tests/*.test.sh; do
		echo "== $$t =="
		bash "$$t" || rc=1
	done
	exit "$$rc"

ci: lint fmt-check test

.DEFAULT_GOAL := all
