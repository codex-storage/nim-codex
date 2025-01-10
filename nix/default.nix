{
  pkgs ? import <nixpkgs> { },
  src ? ../.,
  targets ? ["all"],
  # Options: 0,1,2
  verbosity ? 0,
  # Use system Nim compiler instead of building it with nimbus-build-system
  useSystemNim ? true,
  commit ? builtins.substring 0 7 (src.rev or "dirty"),
  # These are the only platforms tested in CI and considered stable.
  stableSystems ? [
    "x86_64-linux" "aarch64-linux"
    "x86_64-darwin" "aarch64-darwin"
  ],
  circomCompatPkg ? (
    builtins.getFlake "github:codex-storage/circom-compat-ffi"
  ).packages.${builtins.currentSystem}.default
}:

let
  inherit (pkgs) stdenv lib writeScriptBin callPackage;
  
  revision = lib.substring 0 8 (src.rev or "dirty");

  tools = callPackage ./tools.nix {};
in pkgs.gcc11Stdenv.mkDerivation rec {
  
  pname = "nim-codex";

  version = "${tools.findKeyValue "version = \"([0-9]+\.[0-9]+\.[0-9]+)\"" ../codex.nimble}-${revision}";
  
  src = pkgs.fetchFromGitHub {
    owner = "codex-storage";
    repo = "nim-codex";
    rev = "HEAD";
    sha256 = "sha256-cPQDV46Z9z27Hd32eW726fC3J1dAhXyljbhAgFXVEXQ=";
    fetchSubmodules = true;
  };

  # Dependencies that should exist in the runtime environment.
  buildInputs = with pkgs; [
    openssl
    gmp
  ];

  # Dependencies that should only exist in the build environment.
  nativeBuildInputs = let
    # Fix for Nim compiler calling 'git rev-parse' and 'lsb_release'.
    fakeGit = writeScriptBin "git" "echo ${version}";
    # Fix for the nim-circom-compat-ffi package that is built with cargo.
    fakeCargo = writeScriptBin "cargo" "echo ${version}";
  in
    with pkgs; [
      cmake
      pkg-config
      nimble
      which
      nim-unwrapped-1
      lsb-release
      circomCompatPkg
      fakeGit
      fakeCargo
  ];

  # Disable CPU optmizations that make binary not portable.
  NIMFLAGS = "-d:disableMarchNative -d:git_revision_override=${revision}";
  # Avoid Nim cache permission errors.
  XDG_CACHE_HOME = "/tmp";

  makeFlags = targets ++ [
    "V=${toString verbosity}"
    "USE_SYSTEM_NIM=${if useSystemNim then "1" else "0"}"
  ];

  configurePhase = ''
    patchShebangs . > /dev/null
  '';
 
  installPhase = ''
    mkdir -p $out/bin
    cp build/codex $out/bin/
  '';

  meta = with pkgs.lib; {
    description = "Nim Codex storage system";
    homepage = "https://github.com/codex-storage/nim-codex";
    license = licenses.mit;
    platforms = stableSystems;
  };
}
