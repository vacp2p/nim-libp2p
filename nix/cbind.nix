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
    # miniupnpc's Darwin Makefile archives via `LIBTOOL ?= $(shell which libtool)`; cctools supplies it, which resolves it.
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
    # nat_traversal's {.passl: <pkgRoot>/vendor/.../lib*.a.} needs a writable copy: the store is read-only.
    NAT_PKG=$TMPDIR/nat_traversal
    cp -r ${deps.nat_traversal} $NAT_PKG
    chmod -R +w $NAT_PKG
    # Forward $CC; the vendored Makefiles default to CC=gcc, absent on the Darwin stdenv.
    make -C $NAT_PKG/vendor/miniupnp/miniupnpc \
      CC="$CC" CFLAGS="-Os -fPIC" build/libminiupnpc.a
    make -C $NAT_PKG/vendor/libnatpmp-upstream \
      CC="$CC" \
      CFLAGS="-Wall -Os -fPIC -DENABLE_STRNATPMPERR -DNATPMP_MAX_RETRIES=4" \
      libnatpmp.a

    commonArgs="--noNimblePath ${cbindPathArgs} ${pathArgs} --path:$NAT_PKG \
      --threads:on --opt:size --noMain --mm:refc --d:metrics \
      --nimMainPrefix:liblibp2p --nimcache:$NIMCACHE"

    echo "== Building FFI library (dynamic/shared) =="
    nim c $commonArgs --app:lib --out:build/libp2p.${libExt} cbind/libp2p.nim

    echo "== Building FFI library (static) =="
    nim c $commonArgs --app:staticlib --out:build/libp2p.a cbind/libp2p.nim

    echo "== Generating C++ bindings =="
    nim c $commonArgs --app:lib -d:ffiGenBindings -d:targetLang=cpp \
      -d:ffiOutputDir=cbind/cpp_bindings -d:ffiSrcPath=libp2p.nim \
      -o:/dev/null cbind/libp2p.nim

    echo "== Generating CDDL schema =="
    nim c $commonArgs --app:lib -d:ffiGenBindings -d:targetLang=cddl \
      -d:ffiOutputDir=cbind/cddl_bindings -d:ffiSrcPath=libp2p.nim \
      -o:/dev/null cbind/libp2p.nim
  '';

  installPhase = ''
    mkdir -p $out/lib $out/include
    cp build/libp2p.${libExt} $out/lib
    cp build/libp2p.a         $out/lib
    # libp2p.a references these via {.passl.}; install them so static linking resolves.
    cp $NAT_PKG/vendor/miniupnp/miniupnpc/build/libminiupnpc.a $out/lib
    cp $NAT_PKG/vendor/libnatpmp-upstream/libnatpmp.a          $out/lib
    # Install the nim-ffi generated bindings instead of a hand-written header.
    cp -r cbind/cpp_bindings  $out/include/
    cp -r cbind/cddl_bindings $out/include/
  '';
}

