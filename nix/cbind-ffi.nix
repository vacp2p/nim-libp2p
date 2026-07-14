{ pkgs, src }:

# Temporary parallel derivation for the nim-ffi library (cbind/libp2p_ffi.nim),
# built alongside the legacy `.#cbind` while the PR train migrates domain by
# domain. Collapsed back into `nix/cbind.nix` at the flip PR, when
# libp2p_ffi.nim replaces the legacy libp2p.nim.
let
  deps = import ./deps.nix { inherit pkgs; };
  cbindDeps = import ./cbind-deps.nix { inherit pkgs; };

  pathArgs =
    builtins.concatStringsSep " "
      (map (p: "--path:${p}") (builtins.attrValues deps));

  cbindPathArgs =
    builtins.concatStringsSep " "
      (map (p: "--path:${p}") (builtins.attrValues cbindDeps));

  libExt =
    if pkgs.stdenv.hostPlatform.isWindows then "dll"
    else if pkgs.stdenv.hostPlatform.isDarwin then "dylib"
    else "so";
in
pkgs.stdenv.mkDerivation {
  pname = "nim-libp2p-cbind-ffi";
  version = "dev";

  inherit src;

  nativeBuildInputs = [
    pkgs.nim-2_2
    pkgs.git
    pkgs.nimble
  ];

  buildPhase = ''
    export HOME=$TMPDIR
    export XDG_CACHE_HOME=$TMPDIR/.cache
    export NIMBLE_DIR=$TMPDIR/.nimble
    export NIMCACHE=$TMPDIR/nimcache

    mkdir -p build $NIMCACHE

    # libplum's vendored C sources compile into liblibp2p via nim's {.compile.}
    # pragmas, so there is no separate NAT library to build or link.
    #
    # ffiThreadExitTimeoutMs: bound the FFI thread's graceful-shutdown wait; the
    # 1500ms default is too tight for libp2pDestroy's switch.stop() over many conns.
    commonArgs="--noNimblePath ${cbindPathArgs} ${pathArgs} \
      --threads:on --opt:size --noMain --mm:refc --d:metrics \
      -d:ffiThreadExitTimeoutMs=5000 \
      --nimMainPrefix:liblibp2p --nimcache:$NIMCACHE"

    echo "== Building FFI library (dynamic/shared) =="
    nim c $commonArgs --app:lib --out:build/liblibp2p.${libExt} cbind/libp2p_ffi.nim

    echo "== Building FFI library (static) =="
    nim c $commonArgs --app:staticlib --out:build/liblibp2p.a cbind/libp2p_ffi.nim

    echo "== Generating C bindings =="
    nim c $commonArgs --app:lib -d:ffiGenBindings -d:targetLang=c \
      -d:ffiOutputDir=cbind/c_bindings -d:ffiSrcPath=libp2p_ffi.nim \
      -o:/dev/null cbind/libp2p_ffi.nim

    echo "== Generating CDDL schema =="
    nim c $commonArgs --app:lib -d:ffiGenBindings -d:targetLang=cddl \
      -d:ffiOutputDir=cbind/cddl_bindings -d:ffiSrcPath=libp2p_ffi.nim \
      -o:/dev/null cbind/libp2p_ffi.nim
  '';

  installPhase = ''
    mkdir -p $out/lib $out/include
    cp build/liblibp2p.${libExt} $out/lib
    cp build/liblibp2p.a         $out/lib
    # Install nim-ffi's headers (libp2p.h + companions) flat: consumers stage
    # them via `cp $out/include/*.h`, so a nested dir would be missed.
    cp cbind/c_bindings/*.h   $out/include/
    cp -r cbind/cddl_bindings $out/include/
  '';
}
