{
  description = "Codex build flake";
  
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.05";
  };

  outputs = { self, nixpkgs }:
    let
      supportedSystems = [
        "x86_64-linux" "aarch64-linux"
        "x86_64-darwin" "aarch64-darwin"
      ];
      forAllSystems = f: nixpkgs.lib.genAttrs supportedSystems (system: f system);
      pkgsFor = forAllSystems (system: import nixpkgs { inherit system; });
    in rec {
      devShells = forAllSystems (system: let
        pkgs = pkgsFor.${system};
        inherit (pkgs) lib stdenv mkShell;
      in {
        default = mkShell.override { stdenv = pkgs.gcc11Stdenv; } {
          buildInputs = with pkgs; [
              # General
              git pkg-config openssl lsb-release
              # Build
              rustc cargo nim nimble gcc11 cmake
              # Libraries
              gmp llvmPackages.openmp
              # Tests
              nodejs_18
          ];
          shellHook = ''
              export NIMBLE_DIR=$HOME/.nimble
              export RUSTFLAGS="-C target-cpu=native"
              export CXXFLAGS="-std=c++17 -march=native -mtune=native -msse -msse2 -msse3 -mssse3 -msse4.1 -msse4.2 -mavx -mavx2 -fopenmp"
              export CFLAGS="-march=native -mtune=native -msse -msse2 -msse3 -mssse3 -msse4.1 -msse4.2 -mavx -mavx2"
              mkdir -p $NIMBLE_DIR
              echo "Codex build environment loaded."
              echo "GCC path: $(which gcc)"
              echo "G++ path: $(which g++)"
          '';
        };
      });
    };
}