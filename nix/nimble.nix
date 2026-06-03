{ pkgs ? import <nixpkgs> { } }:

let
  tools = pkgs.callPackage ./tools.nix {};
  nbsVersion = tools.findKeyValue "^[[:space:]]+: .*NIMBLE_COMMIT:=([a-f0-9]+).*$" ../vendor/nimbus-build-system/scripts/build_nim.sh;
  nimVersion = tools.findKeyValue "^ +NimbleStableCommit = \"([a-f0-9]+)\".+" ../vendor/nimbus-build-system/vendor/Nim/koch.nim;
  sourceFile = ../vendor/nimbus-build-system/vendor/Nim/koch.nim;
in pkgs.fetchFromGitHub {
  owner = "nim-lang";
  repo = "nimble";
  fetchSubmodules = true;
  rev = if nbsVersion != null then nbsVersion else nimVersion;
  # WARNING: Requires manual updates when Nim compiler version changes.
  hash = "sha256-v0RhIx6ithFJqH6ThKpyvC0JB3CBCevahhCossC+deA=";
}
