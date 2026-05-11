.PHONY: all build deps cbind clean test _test_all testmultiformatexts testintegration testpath \
        install_pinned pin unpin gen_multicodec format

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
  -d:libp2p_autotls_support \
  $(NIMFLAGS)

RUNNER_FLAGS = --output-level=VERBOSE --console

TEST_PATH ?=

all: build

nimble.lock:
	nimble lock

nix/deps.nix: nimble.lock
	./tools/gen-deps.sh nimble.lock nix/deps.nix

deps: nix/deps.nix

build: deps
	nix build

cbind:
	$(MAKE) -C cbind

clean:
	$(RM) nimble.lock nix/deps.nix nimble.paths
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

test: nimble.paths _test_all testmultiformatexts

_test_all: nimble.paths
	$(NIMC) r $(NIM_FLAGS) \
	  $(if $(CICOV),--nimcache:nimcache/test_all,) \
	  tests/test_all.nim -- $(RUNNER_FLAGS) --xml:tests/results_test_all.xml

testmultiformatexts: nimble.paths
	$(NIMC) r $(NIM_FLAGS) \
	  $(if $(CICOV),--nimcache:nimcache/test_all_multiformat,) \
	  -d:libp2p_multicodec_exts=../tests/libp2p/multiformat_exts/multicodec_exts.nim \
	  -d:libp2p_multiaddress_exts=../tests/libp2p/multiformat_exts/multiaddress_exts.nim \
	  -d:libp2p_multihash_exts=../tests/libp2p/multiformat_exts/multihash_exts.nim \
	  -d:libp2p_multibase_exts=../tests/libp2p/multiformat_exts/multibase_exts.nim \
	  -d:libp2p_contentids_exts=../tests/libp2p/multiformat_exts/contentids_exts.nim \
	  -d:path=multiformat_exts \
	  tests/test_all.nim -- $(RUNNER_FLAGS) --xml:tests/results_test_all_multiformat.xml

testintegration: nimble.paths
	$(NIMC) r $(NIM_FLAGS) \
	  $(if $(CICOV),--nimcache:nimcache/integration,) \
	  tests/integration/test_all.nim -- $(RUNNER_FLAGS) --xml:tests/results_integration.xml

testpath: nimble.paths
ifeq ($(TEST_PATH),)
	$(error TEST_PATH is required. Usage: make testpath TEST_PATH=quic)
endif
	$(NIMC) r $(NIM_FLAGS) \
	  $(if $(CICOV),--nimcache:nimcache/test_all,) \
	  -d:path=$(TEST_PATH) \
	  tests/test_all.nim -- $(RUNNER_FLAGS) --xml:tests/results_test_all.xml

# Tasks that still require nimble
install_pinned:
	nimble install_pinned

pin:
	nimble pin

unpin:
	nimble unpin

gen_multicodec:
	nimble gen_multicodec

format:
	nimble format
