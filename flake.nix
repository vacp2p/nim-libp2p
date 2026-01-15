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
      pkgsFor = forEach systems (
        system: import nixpkgs { inherit system; }
      );
    in {
	  packages = forAllSystems (system:
      let
        pkgs = import nixpkgs { inherit system; };
        src = pkgs.lib.cleanSourceWith {
          src = ./.;
          filter = path: type:
            let
              rel = pkgs.lib.removePrefix (toString ./. + "/") (toString path);
            in
            # Include vendor and any other dirs you need
            builtins.match "^(vendor|libp2p|cbind|config\\.nims|nimble\\.lock)/" rel != null;
        };
      in {
        default = pkgs.stdenv.mkDerivation {
          pname = "nim-libp2p";
          version = "dev";
          inherit src;

          nativeBuildInputs = [ pkgs.nim-2_2 pkgs.git pkgs.nimble ];

          buildPhase = ''
            if [ ! -d vendor ]; then
              echo "vendor/ missing. Run ./scripts/vendor.sh"
              exit 1
            fi

            export NIMBLE_PATH=/nonexistent

            nim c \
              --noNimblePath \
              --path:vendor \
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
        };
      }
    );

    devShells = forAllSystems (system:
      let pkgs = import nixpkgs { inherit system; };
      in {
        default = pkgs.mkShell {
          nativeBuildInputs = [ pkgs.nim-2_2 pkgs.nimble ];
        };
      }
    );
  };
}
