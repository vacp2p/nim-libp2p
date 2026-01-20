.PHONY: all build deps cbind-deps cbind

all: build

deps: nimble.lock
	./scripts/gen-deps.sh nimble.lock nix/deps.nix

build: deps
	nix build

cbind-deps: deps cbind/nimble.lock
	./scripts/gen-deps.sh cbind/nimble.lock nix/cbind-deps.nix

cbind: cbind-deps
	nix build .#cbind

