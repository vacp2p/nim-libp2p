.PHONY: all build deps cbind clean test \
        test_multiformat_exts test_integration \
        install_pinned lock gen_multicodec format clean-nim

NIM_VERSION  ?= 2.2.10
NPH_VERSION  ?= 0.7.0

NIMC     ?= nim
NIMFLAGS ?=
V        ?= 0

ifeq ($(V),0)
VERBOSITY_FLAG = --verbosity:0
else
VERBOSITY_FLAG =
endif

NIM_FLAGS = \
  --styleCheck:usages --styleCheck:error \
  $(VERBOSITY_FLAG) \
  --skipUserCfg \
  -f \
  --threads:on \
  --opt:speed \
  $(NIMFLAGS)

RUNNER_FLAGS = --output-level=VERBOSE --console

# Allow: make test [path]
# Captures the optional path argument and synthesises a do-nothing rule for it
# so Make does not complain about a missing target.
ifeq ($(firstword $(MAKECMDGOALS)),test)
  _TEST_PATH_ARG := $(wordlist 2,$(words $(MAKECMDGOALS)),$(MAKECMDGOALS))
  ifneq ($(_TEST_PATH_ARG),)
    override TEST_PATH := $(_TEST_PATH_ARG)
    $(eval $(_TEST_PATH_ARG):;@true)
  endif
endif

TEST_PATH ?=

all: build

nimble.lock: libp2p.nimble
	nimble lock

nix/deps.nix: nimble.lock
	./tools/gen-deps.sh nimble.lock nix/deps.nix

tests/nimble.lock: tests/tests.nimble libp2p.nimble
	cd tests && nimble lock

nix/tests-deps.nix: tests/nimble.lock
	./tools/gen-deps.sh tests/nimble.lock nix/tests-deps.nix unittest2

deps: nix/deps.nix nix/tests-deps.nix

build: deps
	nix build

cbind:
	$(MAKE) -C cbind

clean:
	$(RM) nix/deps.nix nix/tests-deps.nix nimble.paths tests/nimble.paths
	$(MAKE) -C cbind clean

# Generate nimble.paths so config.nims can include it.
# nimble injects per-package srcDir paths that --NimblePath alone doesn't provide;
# this replicates that by reading srcDir from each package's .nimble file.
nimble.paths: $(wildcard nimbledeps/pkgs2/*/*.nimble) $(wildcard nimbledeps/pkgs/*/*.nimble)
	@rm -f $@
	@for pkgdir in nimbledeps/pkgs2 nimbledeps/pkgs; do \
	  [ -d "$$pkgdir" ] || continue; \
	  for f in "$$pkgdir"/*/*.nimble; do \
	    [ -f "$$f" ] || continue; \
	    pkg=$$(dirname "$$f"); \
	    src=$$(sed -n 's/^[[:space:]]*srcDir[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' "$$f" | head -1); \
	    if [ -n "$$src" ] && [ "$$src" != "." ]; then \
	      path="$$pkg/$$src"; \
	    else \
	      path="$$pkg"; \
	    fi; \
	    printf 'switch("path", "%s")\n' "$$path" >> $@; \
	  done; \
	done

tests/nimble.paths: $(wildcard tests/nimbledeps/pkgs2/*/*.nimble) $(wildcard tests/nimbledeps/pkgs/*/*.nimble)
	@rm -f $@
	@for pkgdir in tests/nimbledeps/pkgs2 tests/nimbledeps/pkgs; do \
	  [ -d "$$pkgdir" ] || continue; \
	  for f in "$$pkgdir"/*/*.nimble; do \
	    [ -f "$$f" ] || continue; \
	    pkg=$$(dirname "$$f"); \
	    src=$$(sed -n 's/^[[:space:]]*srcDir[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' "$$f" | head -1); \
	    if [ -n "$$src" ] && [ "$$src" != "." ]; then \
	      path="$$pkg/$$src"; \
	    else \
	      path="$$pkg"; \
	    fi; \
	    printf 'switch("path", "%s")\n' "$$path" >> $@; \
	  done; \
	done

# nim-libplum vendors libplum (PCP / NAT-PMP / UPnP-IGD) as a git submodule and
# compiles its C sources into libp2p via nim's {.compile.} pragmas, so there is
# no separate NAT library to build or link here.

test: nimble.paths tests/nimble.paths
ifeq ($(TEST_PATH),)
	$(NIMC) c $(NIM_FLAGS) \
	  $(if $(CICOV),--nimcache:nimcache/test_all,) \
	  tests/test_all.nim
	./tests/test_all $(RUNNER_FLAGS) --xml:tests/results_test_all.xml
	$(MAKE) test_multiformat_exts
else
	$(NIMC) c $(NIM_FLAGS) \
	  $(if $(CICOV),--nimcache:nimcache/test_all,) \
	  -d:path=$(TEST_PATH) \
	  tests/test_all.nim
	./tests/test_all $(RUNNER_FLAGS) --xml:tests/results_test_all.xml
endif

test_multiformat_exts: nimble.paths tests/nimble.paths
	$(NIMC) c $(NIM_FLAGS) \
	  --nimcache:nimcache/test_all_multiformat \
	  -d:libp2p_multicodec_exts=../tests/libp2p/multiformat_exts/multicodec_exts.nim \
	  -d:libp2p_multiaddress_exts=../tests/libp2p/multiformat_exts/multiaddress_exts.nim \
	  -d:libp2p_multihash_exts=../tests/libp2p/multiformat_exts/multihash_exts.nim \
	  -d:libp2p_multibase_exts=../tests/libp2p/multiformat_exts/multibase_exts.nim \
	  -d:libp2p_contentids_exts=../tests/libp2p/multiformat_exts/contentids_exts.nim \
	  -d:path=multiformat_exts \
	  tests/test_all.nim
	./tests/test_all $(RUNNER_FLAGS) --xml:tests/results_test_all_multiformat.xml

test_integration: nimble.paths tests/nimble.paths
	$(NIMC) c $(NIM_FLAGS) \
	  $(if $(CICOV),--nimcache:nimcache/integration,) \
	  tests/integration/test_all.nim
	./tests/integration/test_all $(RUNNER_FLAGS) --xml:tests/results_integration.xml

install_pinned:
	nimble --useSystemNim -l install -dy
	cd tests && nimble --useSystemNim -l install -dy

lock:
	nimble lock
	cd tests && nimble lock
	$(MAKE) -C cbind nimble.lock

gen_multicodec:
	nimble gen_multicodec

format:
	find . -name '*.nim' -not -path './nimbledeps/*' -not -path './tests/nimbledeps/*' | xargs nph

clean-nim:
	[ ! -d nimbledeps ] || rm -rf nimbledeps
	[ ! -d tests/nimbledeps ] || rm -rf tests/nimbledeps
	rm nimble.paths tests/nimble.paths 2>/dev/null || true
