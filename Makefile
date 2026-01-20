.PHONY: all build

all: build

build:
	./scripts/gen-deps.sh
	nix build

