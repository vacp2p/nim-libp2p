{ pkgs, src }:

let
  rawDeps = import ./deps.nix { inherit pkgs; };
  cbindDeps = import ./cbind-deps.nix { inherit pkgs; };

  # Replace nat_traversal with a copy whose vendored miniupnpc / libnatpmp
  # static archives are prebuilt in-tree. The wrappers' `{.passL.}` paths are
  # currentSourcePath-relative, so the linker needs the .a files alongside the
  # Nim sources — separate derivation outputs won't satisfy them.
  natTraversal = import ./nat-libs.nix {
    inherit pkgs;
    natSrc = rawDeps.nat_traversal;
  };
  deps = rawDeps // { nat_traversal = natTraversal; };

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

    echo "== Building C bindings (dynamic/shared) =="
    # A shared library is fully linked, so it must resolve the miniupnpc /
    # libnatpmp C symbols. The nat_traversal wrappers reference the vendored
    # static archives via `{.passL.}` paths relative to their own source dir;
    # we route --path:nat_traversal to a copy with those archives prebuilt
    # in-tree, so the linker finds them at the expected location. The static
    # build below only archives Nim objects, so its consumer links these later.
    nim c \
      --noNimblePath \
      ${cbindPathArgs} \
      ${pathArgs} \
      --path:${deps.dnsclient}/src \
      --out:build/libp2p.${libExt} \
      --app:lib \
      --threads:on \
      --opt:size \
      --noMain \
      --mm:refc \
      --header \
      --undef:metrics \
      --nimMainPrefix:libp2p \
      --nimcache:$NIMCACHE \
      cbind/libp2p.nim

    echo "== Building C bindings (static) =="
    nim c \
      --noNimblePath \
      ${cbindPathArgs} \
      ${pathArgs} \
      --path:${deps.dnsclient}/src \
      --out:build/libp2p.a \
      --app:staticlib \
      --threads:on \
      --opt:size \
      --noMain \
      --mm:refc \
      --header \
      --undef:metrics \
      --nimMainPrefix:libp2p \
      --nimcache:$NIMCACHE \
      cbind/libp2p.nim
  '';

  installPhase = ''
    mkdir -p $out/lib $out/include
    cp build/libp2p.${libExt} $out/lib
    cp build/libp2p.a         $out/lib
    cp cbind/libp2p.h         $out/include
  '';
}

