{
  description = "Logos Storage build flake";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";
    circom-compat = {
      url = "github:logos-storage/circom-compat-ffi";
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
        buildTarget = pkgsFor.${system}.callPackage ./nix/default.nix rec {
          inherit stableSystems circomCompatPkg;
          src = self;
        };
        build = targets: buildTarget.override { inherit targets; };
      in rec {
        logos-storage-nim   = build ["all"];
        libstorage = build ["libstorage"];
        default = logos-storage-nim;
      });

      nixosModules.logos-storage-nim = { config, lib, pkgs, ... }: import ./nix/service.nix {
        inherit config lib pkgs self;
        circomCompatPkg = circom-compat.packages.${pkgs.system}.default;
      };

      devShells = forAllSystems (system: let
        pkgs = pkgsFor.${system};
      in {
        default = pkgs.mkShell {
          inputsFrom = [
            packages.${system}.logos-storage-nim
            packages.${system}.libstorage
            circom-compat.packages.${system}.default
          ];
          # Not using buildInputs to override fakeGit and fakeCargo.
          nativeBuildInputs = with pkgs; [ git cargo nodejs_18 ];
        };
      });

      checks = forAllSystems (system: let
        pkgs = pkgsFor.${system};
      in {
        logos-storage-nim-test = pkgs.nixosTest {
          name = "logos-storage-nim-test";
          nodes = {
            server = { config, pkgs, ... }: {
              imports = [ self.nixosModules.logos-storage-nim ];
              services.logos-storage-nim.enable = true;
              services.logos-storage-nim.settings = {
                data-dir = "/var/lib/logos-storage-nim-test";
              };
              systemd.services.logos-storage-nim.serviceConfig.StateDirectory = "logos-storage-nim-test";
            };
          };
          testScript = ''
            print("Starting test: logos-storage-nim-test")
            machine.start()
            machine.wait_for_unit("logos-storage-nim.service")
            machine.succeed("test -d /var/lib/logos-storage-nim-test")
            machine.wait_until_succeeds("journalctl -u logos-storage-nim.service | grep 'Started Storage node'", 10)
          '';
        };
      });
    };
}