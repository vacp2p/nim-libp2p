{ pkgs, src }:

let
  deps = import ./deps.nix { inherit pkgs; };
  cbindDeps = import ./cbind-deps.nix { inherit pkgs; };

  # nat_traversal is resolved from a writable copy (see buildPhase), not the store.
  depsWithoutNat = builtins.removeAttrs deps [ "nat_traversal" ];

  pathArgs =
    builtins.concatStringsSep " "
      (map (p: "--path:${p}") (builtins.attrValues depsWithoutNat));

  cbindPathArgs =
    builtins.concatStringsSep " "
      (map (p: "--path:${p}") (builtins.attrValues cbindDeps));

  libExt =
    if pkgs.stdenv.hostPlatform.isWindows then "dll"
    else if pkgs.stdenv.hostPlatform.isDarwin then "dylib"
    else "so";
in
pkgs.stdenv.mkDerivation {
  pname = "nim-libp2p-cbind";
  version = "dev";

  inherit src;

  nativeBuildInputs = [
    pkgs.nim-2_2
    pkgs.git
    pkgs.nimble
  ] ++ pkgs.lib.optionals pkgs.stdenv.hostPlatform.isDarwin [
    # miniupnpc's Darwin Makefile archives via `LIBTOOL ?= $(shell which libtool)`.
    # cctools supplies Apple's `libtool`; `which` lets the lookup resolve it.
    # Without both, LIBTOOL collapses to empty and no .a is produced.
    pkgs.cctools
    pkgs.which
  ];

  buildPhase = ''
    export HOME=$TMPDIR
    export XDG_CACHE_HOME=$TMPDIR/.cache
    export NIMBLE_DIR=$TMPDIR/.nimble
    export NIMCACHE=$TMPDIR/nimcache

    mkdir -p build $NIMCACHE

    echo "== Building nat_traversal vendored C libs =="
    # nat_traversal emits {.passl: <pkgRoot>/vendor/.../lib*.a.}; the store copy
    # is read-only, so stage a writable copy and build the .a files in place.
    NAT_PKG=$TMPDIR/nat_traversal
    cp -r ${deps.nat_traversal} $NAT_PKG
    chmod -R +w $NAT_PKG
    # The vendored Makefiles default to CC=gcc, absent on the Darwin stdenv;
    # forward $CC (wrapped gcc on Linux, clang on Darwin).
    make -C $NAT_PKG/vendor/miniupnp/miniupnpc \
      CC="$CC" CFLAGS="-Os -fPIC" build/libminiupnpc.a
    make -C $NAT_PKG/vendor/libnatpmp-upstream \
      CC="$CC" \
      CFLAGS="-Wall -Os -fPIC -DENABLE_STRNATPMPERR -DNATPMP_MAX_RETRIES=4" \
      libnatpmp.a

    commonArgs="--noNimblePath ${cbindPathArgs} ${pathArgs} --path:$NAT_PKG \
      --threads:on --opt:size --noMain --mm:refc --header --d:metrics \
      --nimMainPrefix:libp2p --nimcache:$NIMCACHE"

    echo "== Building C bindings (dynamic/shared) =="
    nim c $commonArgs --app:lib --out:build/libp2p.${libExt} cbind/libp2p.nim

    echo "== Building C bindings (static) =="
    nim c $commonArgs --app:staticlib --out:build/libp2p.a cbind/libp2p.nim
  '';

  installPhase = ''
    mkdir -p $out/lib $out/include
    cp build/libp2p.${libExt} $out/lib
    cp build/libp2p.a         $out/lib
    cp cbind/libp2p.h         $out/include
  '';
}

