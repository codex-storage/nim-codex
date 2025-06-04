{ pkgs ? import <nixpkgs> { } }:

let
  tools = pkgs.callPackage ./tools.nix {};
  sourceFile = ../vendor/nimbus-build-system/vendor/Nim/config/build_config.txt;
in pkgs.fetchFromGitHub {
  owner = "nim-lang";
  repo = "csources_v2";
  rev = "86742fb02c6606ab01a532a0085784effb2e753e";
  # WARNING: Requires manual updates when Nim compiler version changes.
  hash = "sha256-UCLtoxOcGYjBdvHx7A47x6FjLMi6VZqpSs65MN7fpBs=";
}
