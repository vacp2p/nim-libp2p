.PHONY: all build deps test testpath testmultiformatexts testintegration cbind clean

NIMBLE ?= nimble
TEST_PATH ?=

all: build

nimble.lock:
	$(NIMBLE) lock

nix/deps.nix: nimble.lock
	./tools/gen-deps.sh nimble.lock nix/deps.nix

deps: nix/deps.nix

build: deps
	nix build

test:
	$(NIMBLE) test

testmultiformatexts:
	$(NIMBLE) testmultiformatexts

testintegration:
	$(NIMBLE) testintegration

testpath:
ifndef TEST_PATH
	$(error TEST_PATH is required. Usage: make testpath TEST_PATH=quic)
endif
ifeq ($(strip $(TEST_PATH)),)
	$(error TEST_PATH is required. Usage: make testpath TEST_PATH=quic)
endif
	$(NIMBLE) testpath $(TEST_PATH)

# Delegate to cbind/Makefile
cbind:
	$(MAKE) -C cbind

clean:
	$(RM) nimble.lock nix/deps.nix
	$(MAKE) -C cbind clean

