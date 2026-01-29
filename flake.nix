{
  description = "Logos Storage build flake";

  inputs = {
    # We are pinning the commit because ultimately we want to use same commit across different projects.
    # A commit from nixpkgs 24.11 release : https://github.com/NixOS/nixpkgs/tree/release-24.11
    nixpkgs.url = "github:NixOS/nixpkgs/0ef228213045d2cdb5a169a95d63ded38670b293";
    nimbusBuildSystem = {
      url = "git+file:./vendor/nimbus-build-system?submodules=1";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, nimbusBuildSystem }: let
    stableSystems = [
      "x86_64-linux" "aarch64-linux"
      "x86_64-darwin" "aarch64-darwin"
    ];
    forAllSystems = f: nixpkgs.lib.genAttrs stableSystems (system: f system);
    pkgsFor = forAllSystems (system: import nixpkgs { inherit system; });
  in rec {
    packages = forAllSystems (system: let
      nim = nimbusBuildSystem.packages.${system}.nim;
      buildTarget = pkgsFor.${system}.callPackage ./nix/default.nix rec {
        inherit stableSystems nim;
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
    };

    devShells = forAllSystems (system: let
      pkgs = pkgsFor.${system};
      nim = nimbusBuildSystem.packages.${system}.nim;
    in {
      default = pkgs.mkShell {
        inputsFrom = [
          packages.${system}.logos-storage-nim
          packages.${system}.libstorage
        ];
        # Not using buildInputs to override fakeGit.
        nativeBuildInputs = with pkgs; [ nim git cargo nodejs_20 ];
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
