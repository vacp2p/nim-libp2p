.PHONY: all build genbindings deps nixbuild clean

NIM_VERSION ?= 2.2.10

all: build genbindings

# Builds ../build/liblibp2p.so plus the C/CDDL bindings. Run `nimble setup` once first.
build:
	nimble -l buildffi

genbindings:
	nimble -l genbindings_c
	nimble -l genbindings_cddl

nimble.lock: cbind.nimble
	nimble --requires:"nim == $(NIM_VERSION)" lock

../nix/cbind-deps.nix: nimble.lock
	../tools/gen-deps.sh nimble.lock ../nix/cbind-deps.nix taskpools cbor_serialization ffi

deps: ../nix/cbind-deps.nix

nixbuild: deps
	nix build .#cbind

clean:
	$(RM) -r c_bindings cddl_bindings nimcache nimcache_c nimcache_cddl
