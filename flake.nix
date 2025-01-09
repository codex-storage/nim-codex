{
  description = "Codex build flake";
  
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";
    circom-compat = {
      url = "github:codex-storage/circom-compat-ffi/afadf4d9a411ce0589f6b4c1858a9a5a4e7f4661";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, circom-compat}:
    let
      stableSystems = [
        "x86_64-linux" "aarch64-linux"
        "x86_64-darwin" "aarch64-darwin"
      ];
      forAllSystems = f: nixpkgs.lib.genAttrs stableSystems (system: f system);
      pkgsFor = forAllSystems (system: import nixpkgs { inherit system; });
    in rec {
      packages = forAllSystems (system: let
        circomCompatPkg = circom-compat.packages.${system}.default;
        buildTarget = pkgsFor.${system}.callPackage ./nix/default.nix {
          inherit stableSystems circomCompatPkg;
          src = self;
        };
        build = targets: buildTarget.override { inherit targets; };
      in rec {
        codex   = build ["all"];
        default = codex;
      });

      devShells = forAllSystems (system: let
        pkgs = pkgsFor.${system};
      in {
        default = pkgs.mkShell {
          inputsFrom = [
            packages.${system}.codex
            circom-compat.packages.${system}.default
          ];
          # Not using buildInputs to override fakeGit and fakeCargo.
          nativeBuildInputs = with pkgs; [ git cargo nodejs_18 ];
        };
      });
    };
}