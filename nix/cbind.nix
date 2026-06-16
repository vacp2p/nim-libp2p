{ pkgs, src }:

let
  deps = import ./deps.nix { inherit pkgs; };
  cbindDeps = import ./cbind-deps.nix { inherit pkgs; };

  # nat_traversal's nim sources emit {.passl: <pkgRoot>/vendor/.../lib*.a.},
  # so the writable copy that holds the freshly built vendored .a files must
  # also be the path nim resolves the package from.
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
  ];

  buildPhase = ''
    export HOME=$TMPDIR
    export XDG_CACHE_HOME=$TMPDIR/.cache
    export NIMBLE_DIR=$TMPDIR/.nimble
    export NIMCACHE=$TMPDIR/nimcache

    mkdir -p build $NIMCACHE

    echo "== Building nat_traversal vendored C libs =="
    # nim-nat-traversal vendors miniupnpc and libnatpmp as C sources and emits
    # {.passl: <pkgRoot>/vendor/.../lib*.a.} from its nim modules. The nix store
    # copy is read-only, so stage a writable copy and build the .a files there.
    NAT_PKG=$TMPDIR/nat_traversal
    cp -r ${deps.nat_traversal} $NAT_PKG
    chmod -R +w $NAT_PKG
    make -C $NAT_PKG/vendor/miniupnp/miniupnpc \
      CFLAGS="-Os -fPIC" build/libminiupnpc.a
    make -C $NAT_PKG/vendor/libnatpmp-upstream \
      CFLAGS="-Wall -Os -fPIC -DENABLE_STRNATPMPERR -DNATPMP_MAX_RETRIES=4" \
      libnatpmp.a

    echo "== Building C bindings (dynamic/shared) =="
    nim c \
      --noNimblePath \
      ${cbindPathArgs} \
      ${pathArgs} \
      --path:$NAT_PKG \
      --out:build/libp2p.${libExt} \
      --app:lib \
      --threads:on \
      --opt:size \
      --noMain \
      --mm:refc \
      --header \
      -d:metrics \
      --nimMainPrefix:libp2p \
      --nimcache:$NIMCACHE \
      cbind/libp2p.nim

    echo "== Building C bindings (static) =="
    nim c \
      --noNimblePath \
      ${cbindPathArgs} \
      ${pathArgs} \
      --path:$NAT_PKG \
      --out:build/libp2p.a \
      --app:staticlib \
      --threads:on \
      --opt:size \
      --noMain \
      --mm:refc \
      --header \
      -d:metrics \
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

