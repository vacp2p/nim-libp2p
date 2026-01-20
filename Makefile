.PHONY: all build deps cbind-deps cbind clean

all: build

nimble.lock:
	nimble lock

deps: nimble.lock
	./scripts/gen-deps.sh nimble.lock nix/deps.nix

build: deps
	nix build

cbind/nimble.lock:
	cd cbind && nimble lock

cbind-deps: deps cbind/nimble.lock
	./scripts/gen-deps.sh cbind/nimble.lock nix/cbind-deps.nix

cbind: cbind-deps
	nix build .#cbind

clean:
	$(RM) nimble.lock cbind/nimble.lock nix/deps.nix nix/cbind-deps.nix

