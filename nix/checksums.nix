{ pkgs ? import <nixpkgs> { } }:

let
  tools = pkgs.callPackage ./tools.nix {};
  sourceFile = ../vendor/nimbus-build-system/vendor/Nim/koch.nim;
in pkgs.fetchFromGitHub {
  owner = "nim-lang";
  repo = "checksums";
  rev = "f8f6bd34bfa3fe12c64b919059ad856a96efcba0";
  # WARNING: Requires manual updates when Nim compiler version changes.
  hash = "sha256-JZhWqn4SrAgNw/HLzBK0rrj3WzvJ3Tv1nuDMn83KoYY=";
}
