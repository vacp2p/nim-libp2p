.PHONY: all deps build clean

all: build

nimble.lock:
	nimble lock

../nix/cbind-deps.nix: nimble.lock
	../tools/gen-deps.sh nimble.lock ../nix/cbind-deps.nix

deps: ../nix/cbind-deps.nix

build: deps
	nix build .#cbind

clean:
	$(RM) nimble.lock ../nix/cbind-deps.nix

