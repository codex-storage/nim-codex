{
  description = "Codex build flake";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};

        # Create a dummy lsb_release script
        dummy-lsb-release = pkgs.writeScriptBin "lsb_release" ''
          #!${pkgs.stdenv.shell}
          echo "Distributor ID: NixOS"
          echo "Description:    NixOS"
          echo "Release:        Unstable"
          echo "Codename:       nixos"
        '';
      in {
        devShell = pkgs.mkShell {
            buildInputs = with pkgs; [
                gcc11
                cmake
                git
                rustc
                cargo
                bash
                pkg-config
                openssl
                gmp
                dummy-lsb-release
                nim
                nimble
                nodejs_18
                llvmPackages.openmp
            ];

            shellHook = ''
                export PATH=${pkgs.gcc11}/bin:${dummy-lsb-release}/bin:$PATH
                export CC=${pkgs.gcc11}/bin/gcc
                export CXX=${pkgs.gcc11}/bin/g++
                export CXXFLAGS="-std=c++17 -march=native -mtune=native -msse -msse2 -msse3 -mssse3 -msse4.1 -msse4.2 -mavx -mavx2 -fopenmp"
                export CFLAGS="-march=native -mtune=native -msse -msse2 -msse3 -mssse3 -msse4.1 -msse4.2 -mavx -mavx2"
                export NIM_COMPILER_PATH=${pkgs.nim}/bin
                export NIMBLE_DIR=$HOME/.nimble
                export RUSTFLAGS="-C target-cpu=native"
                mkdir -p $NIMBLE_DIR
                echo "Codex build environment loaded"
                echo "GCC path: $(which gcc)"
                echo "G++ path: $(which g++)"
            '';
        };
      }
    );
}
