.PHONY: all build deps cbind-deps cbind clean

all: build

nimble.lock:
	nimble lock

nix/deps.nix: nimble.lock
	./tools/gen-deps.sh nimble.lock nix/deps.nix

deps: nix/deps.nix

build: deps
	nix build

cbind/nimble.lock:
	cd cbind && nimble lock

nix/cbind-deps.nix: cbind/nimble.lock
	./tools/gen-deps.sh cbind/nimble.lock nix/cbind-deps.nix

cbind-deps: nix/cbind-deps.nix

cbind: cbind-deps
	nix build .#cbind

clean:
	$(RM) nimble.lock cbind/nimble.lock nix/deps.nix nix/cbind-deps.nix

