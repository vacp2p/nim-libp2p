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
		let pkgs = import nixpkgs { inherit system; };
		in {
		  default = pkgs.stdenv.mkDerivation {
			pname = "nim-libp2p";
			version = "dev";
			src = ./.;

			nativeBuildInputs = [ pkgs.nim-2_2 pkgs.nimble pkgs.cacert pkgs.git ];

             buildPhase = ''
				export HOME=$TMPDIR

				# Make sure Nimble sees the lockfile
				cp ${./nimble.lock} nimble.lock

				# DO NOT refresh the registry
				nimble install --depsOnly --noRefresh --verbose
				nimble build --noRefresh --verbose
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
