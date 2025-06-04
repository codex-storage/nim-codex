{ pkgs ? import <nixpkgs> { } }:

let
  tools = pkgs.callPackage ./tools.nix {};
  sourceFile = ../vendor/nimbus-build-system/vendor/Nim/koch.nim;
in pkgs.fetchFromGitHub {
  owner = "nim-lang";
  repo = "atlas";
  rev = "26cecf4d0cc038d5422fc1aa737eec9c8803a82b";
  # WARNING: Requires manual updates when Nim compiler version changes.
  hash = "sha256-k5/42XFjIMWYL1bxTKkHIOgjaEEqB68hOIpW3N/ub3E=";
}