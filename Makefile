.PHONY: all build deps cbind clean

all: build

nimble.lock:
	nimble lock

nix/deps.nix: nimble.lock
	./tools/gen-deps.sh nimble.lock nix/deps.nix

deps: nix/deps.nix

build: deps
	nix build

# Delegate to cbind/Makefile
cbind:
	$(MAKE) -C cbind

clean:
	$(RM) nimble.lock nix/deps.nix
	$(MAKE) -C cbind clean

