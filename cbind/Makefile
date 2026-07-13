.PHONY: all build genbindings deps nixbuild clean

all: build genbindings

# Builds ../build/liblibp2p.so plus the C/CDDL bindings. Run `nimble setup` once first.
build:
	nimble buildffi

genbindings:
	nimble genbindings_c
	nimble genbindings_cddl

nimble.lock:
	nimble lock

../nix/cbind-deps.nix: nimble.lock
	../tools/gen-deps.sh nimble.lock ../nix/cbind-deps.nix

deps: ../nix/cbind-deps.nix

nixbuild: deps
	nix build .#cbind

clean:
	$(RM) nimble.lock ../nix/cbind-deps.nix
	$(RM) -r c_bindings cddl_bindings nimcache nimcache_c nimcache_cddl
