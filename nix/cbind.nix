{ pkgs, src }:

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
  pname = "nim-libp2p-cbind";
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

    # libplum's vendored C sources compile into libp2p via nim's {.compile.}
    # pragmas, so there is no separate NAT library to build or link.
    commonArgs="--noNimblePath ${cbindPathArgs} ${pathArgs} \
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

