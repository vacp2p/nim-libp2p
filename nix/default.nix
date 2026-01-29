{ pkgs, src }:

let
  deps = import ./deps.nix { inherit pkgs; };
  pathArgs =
    builtins.concatStringsSep " "
      (map (p: "--path:${p}") (builtins.attrValues deps));
in
pkgs.stdenv.mkDerivation {
  pname = "nim-libp2p";
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

    echo "== Building pure Nim objects =="
    nim c \
      --noNimblePath \
      ${pathArgs} \
      --path:${deps.dnsclient}/src \
      --compileOnly \
      --styleCheck:usages \
      --styleCheck:error \
      --skipUserCfg \
      --threads:on \
      --opt:speed \
      -d:libp2p_autotls_support \
      -d:libp2p_mix_experimental_exit_is_dest \
      -d:libp2p_gossipsub_1_4 \
      libp2p.nim
  '';
}

