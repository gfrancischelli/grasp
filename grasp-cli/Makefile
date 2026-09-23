BIN     := grasp
PREFIX  ?= $(HOME)/.local
VERSION := $(shell git describe --tags --always --dirty 2>/dev/null || echo dev)
LDFLAGS := -X github.com/gfrancischelli/grasp/grasp-cli/internal/cli.version=$(VERSION)

build: ## Build the binary (version stamped from git)
	go build -ldflags '$(LDFLAGS)' -o $(BIN) .

install: build ## Build and symlink into PREFIX/bin — a later `make build` is instantly live
	mkdir -p $(PREFIX)/bin
	ln -sf $(CURDIR)/$(BIN) $(PREFIX)/bin/$(BIN)
	@echo "installed: $(PREFIX)/bin/$(BIN) -> $(CURDIR)/$(BIN)"

uninstall: ## Remove the symlink
	rm -f $(PREFIX)/bin/$(BIN)

test: ## Run the tests
	go test ./...

vet: ## Static checks
	go vet ./...

fmt: ## Format the source
	gofmt -w .

check: vet build ## What CI would run
	node --check internal/webserver/ui/app.js

clean:
	rm -f $(BIN)

help: ## List targets
	@grep -E '^[a-z-]+:.*##' $(MAKEFILE_LIST) | sed 's/:.*## /\t/' | column -t -s '	'

.PHONY: build install uninstall test vet fmt check clean help
.DEFAULT_GOAL := build
