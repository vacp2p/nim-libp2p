.PHONY: all build deps cbind clean test _test_all test_multiformat_exts test_integration \
        install_pinned pin unpin gen_multicodec format clean-nim nat_libs

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
  -d:libp2p_autotls_support \
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

# nim-nat-traversal ships miniupnpc and libnatpmp as vendored C sources but does
# not reliably build them via nimble's install hook. Locate the installed
# package dir (it carries a version + commit-hash suffix) and invoke each
# vendor Makefile directly, matching the approach in nwaku's Nat.mk.
NAT_PKG_DIR := $(firstword $(wildcard nimbledeps/pkgs2/nat_traversal-*))
NAT_UPNP_LIB := $(NAT_PKG_DIR)/vendor/miniupnp/miniupnpc/build/libminiupnpc.a
NAT_PMP_LIB  := $(NAT_PKG_DIR)/vendor/libnatpmp-upstream/libnatpmp.a

# Use gcc rather than `cc` so the linux-i386 wrapper (external/bin/gcc, which
# injects -m32) is picked up. On macOS and llvm-mingw, `gcc` is a clang
# compatibility shim, so this stays ABI-compatible with nim's choice.
NAT_CC ?= gcc

ifeq ($(OS),Windows_NT)
  NAT_UPNP_MAKE_ARGS = -f Makefile.mingw CC=$(NAT_CC) build/libminiupnpc.a
  NAT_PMP_CFLAGS = -Wall -Os -fPIC -DENABLE_STRNATPMPERR -DNATPMP_MAX_RETRIES=4 -DWIN32 -DNATPMP_STATICLIB
else
  NAT_UPNP_MAKE_ARGS = CC=$(NAT_CC) CFLAGS="-Os -fPIC" build/libminiupnpc.a
  NAT_PMP_CFLAGS = -Wall -Os -fPIC -DENABLE_STRNATPMPERR -DNATPMP_MAX_RETRIES=4
endif

# Stamp-based rebuild: if the recipe ever runs in this checkout, the stamp
# records "the .a files in this package dir were built by our recipe with the
# right compiler". Without it, we'd see the .a files dropped by nimble's
# `before install` hook (which uses `cc`, not the gcc wrapper that injects -m32
# on i386) or a stale cache restored from another OS/arch, and skip rebuild.
NAT_LIBS_STAMP := $(NAT_PKG_DIR)/.libp2p-nat-libs.stamp

nat_libs: $(NAT_LIBS_STAMP)

.PHONY: nat_pkg_dir_check
nat_pkg_dir_check:
	@test -n "$(NAT_PKG_DIR)" || \
	  (echo "Error: nat_traversal package not found under nimbledeps/pkgs2/. Run 'nimble install_pinned' first." && exit 1)

$(NAT_LIBS_STAMP): | nat_pkg_dir_check
	rm -f "$(NAT_UPNP_LIB)" "$(NAT_PMP_LIB)"
	-$(MAKE) -C "$(NAT_PKG_DIR)/vendor/miniupnp/miniupnpc" clean
	-$(MAKE) -C "$(NAT_PKG_DIR)/vendor/libnatpmp-upstream" clean
	$(MAKE) -C "$(NAT_PKG_DIR)/vendor/miniupnp/miniupnpc" $(NAT_UPNP_MAKE_ARGS)
	$(MAKE) -C "$(NAT_PKG_DIR)/vendor/libnatpmp-upstream" CC=$(NAT_CC) CFLAGS="$(NAT_PMP_CFLAGS)" libnatpmp.a
	touch "$@"

test: nimble.paths nat_libs
ifeq ($(TEST_PATH),)
	$(MAKE) _test_all
	$(MAKE) test_multiformat_exts
else
	$(NIMC) c $(NIM_FLAGS) \
	  $(if $(CICOV),--nimcache:nimcache/test_all,) \
	  -d:path=$(TEST_PATH) \
	  tests/test_all.nim
	./tests/test_all $(RUNNER_FLAGS) --xml:tests/results_test_all.xml
endif

_test_all: nimble.paths nat_libs
	$(NIMC) c $(NIM_FLAGS) \
	  $(if $(CICOV),--nimcache:nimcache/test_all,) \
	  tests/test_all.nim
	./tests/test_all $(RUNNER_FLAGS) --xml:tests/results_test_all.xml

test_multiformat_exts: nimble.paths nat_libs
	$(NIMC) c $(NIM_FLAGS) \
	  $(if $(CICOV),--nimcache:nimcache/test_all_multiformat,) \
	  -d:libp2p_multicodec_exts=../tests/libp2p/multiformat_exts/multicodec_exts.nim \
	  -d:libp2p_multiaddress_exts=../tests/libp2p/multiformat_exts/multiaddress_exts.nim \
	  -d:libp2p_multihash_exts=../tests/libp2p/multiformat_exts/multihash_exts.nim \
	  -d:libp2p_multibase_exts=../tests/libp2p/multiformat_exts/multibase_exts.nim \
	  -d:libp2p_contentids_exts=../tests/libp2p/multiformat_exts/contentids_exts.nim \
	  -d:path=multiformat_exts \
	  tests/test_all.nim
	./tests/test_all $(RUNNER_FLAGS) --xml:tests/results_test_all_multiformat.xml

test_integration: nimble.paths nat_libs
	$(NIMC) c $(NIM_FLAGS) \
	  $(if $(CICOV),--nimcache:nimcache/integration,) \
	  tests/integration/test_all.nim
	./tests/integration/test_all $(RUNNER_FLAGS) --xml:tests/results_integration.xml

install_pinned:
	nimble install_pinned

pin:
	nimble pin

unpin:
	nimble unpin

gen_multicodec:
	nimble gen_multicodec

format:
	find . -name '*.nim' -not -path './nimbledeps/*' | xargs nph

clean-nim:
	[ ! -d nimbledeps ] || rm -rf nimbledeps
	rm nimble.locks nimble.paths 2>/dev/null || true
