{
  description = "nim-libp2p dev shell flake";

  nixConfig = {
    extra-substituters = [ "https://nix-cache.status.im/" ];
    extra-trusted-public-keys = [ "nix-cache.status.im-1:x/93lOfLU+duPplwMSBR+OlY4+mo+dCN7n0mr4oPwgY=" ];
  };

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.05";
  };

  outputs = { self, nixpkgs }:
    let
      systems = [
        "x86_64-linux" "aarch64-linux" "armv7a-linux"
        "x86_64-darwin" "aarch64-darwin"
        "x86_64-windows"
      ];
      forEach = nixpkgs.lib.genAttrs;
      forAllSystems = forEach systems;
    in {
      packages = forAllSystems (system:
        let
          pkgs = import nixpkgs { inherit system; };
          libp2pDeps = import ./nix/libp2p-deps.nix { inherit pkgs; };
          libp2pPathArgs =
            builtins.concatStringsSep " "
              (map (p: "--path:${p}")
                   (builtins.attrValues libp2pDeps));
          cbindDeps = import ./nix/cbind-deps.nix { inherit pkgs; };
          cbindPathArgs =
            builtins.concatStringsSep " "
              (map (p: "--path:${p}")
                   (builtins.attrValues cbindDeps));
        in {
          default = pkgs.stdenv.mkDerivation {
            pname = "nim-libp2p";
            version = "dev";

            src = ./.;

            nativeBuildInputs = [
              pkgs.nim-2_2
              pkgs.git
              pkgs.nimble
            ];

            buildPhase = ''
              # make sure nim writes to a writable dir
              export HOME=$TMPDIR
              export XDG_CACHE_HOME=$TMPDIR/.cache
              export NIMBLE_DIR=$TMPDIR/.nimble

              mkdir -p build
              mkdir -p $TMPDIR/nimcache

              echo "== Building pure Nim objects =="
              nim c \
                --noNimblePath \
                ${libp2pPathArgs} \
                --path:${libp2pDeps.dnsclient}/src \
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

              echo "== Building C bindings (shared lib) =="
              nim c \
                --noNimblePath \
                ${cbindPathArgs} \
                ${libp2pPathArgs} \
                --path:${libp2pDeps.dnsclient}/src \
                --out:build/libp2p.so \
                --app:lib \
                --threads:on \
                --opt:size \
                --noMain \
                --mm:refc \
                --header \
                --undef:metrics \
                --nimMainPrefix:libp2p \
                --nimcache:$TMPDIR/nimcache \
                cbind/libp2p.nim

              echo "== Building C bindings (static lib) =="
              nim c \
                --noNimblePath \
                ${cbindPathArgs} \
                ${libp2pPathArgs} \
                --path:${libp2pDeps.dnsclient}/src \
                --out:build/libp2p.a \
                --app:staticlib \
                --threads:on \
                --opt:size \
                --noMain \
                --mm:refc \
                --header \
                --undef:metrics \
                --nimMainPrefix:libp2p \
                --nimcache:$TMPDIR/nimcache \
                cbind/libp2p.nim
            '';
          };
        }
      );

      devShells = forAllSystems (system:
        let
          pkgs = import nixpkgs { inherit system; };
          deps = import ./nix/deps.nix { inherit pkgs; };
        in {
          default = pkgs.mkShell {
            nativeBuildInputs = [
              pkgs.nim-2_2
              pkgs.nimble
              pkgs.makeWrapper
            ];
          };
        }
      );
    };
}

