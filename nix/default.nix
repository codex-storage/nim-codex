{
  pkgs ? import <nixpkgs> { },
  src ? ../.,
  # Nimbus-build-system package.
  nim ? null,
  # Options: 0,1,2
  verbosity ? 1,
  # Make targets
  targets ? ["all"],
  # These are the only platforms tested in CI and considered stable.
  stableSystems ? [
    "x86_64-linux" "aarch64-linux"
    "x86_64-darwin" "aarch64-darwin"
  ],
}:

assert pkgs.lib.assertMsg ((src.submodules or true) == true)
  "Unable to build without submodules. Append '?submodules=1#' to the URI.";

let
  inherit (pkgs) lib writeScriptBin callPackage;


  tools = callPackage ./tools.nix {};

  version = tools.findKeyValue "version = \"([0-9]+\.[0-9]+\.[0-9]+)\"" ../codex.nimble;
  revision = lib.substring 0 8 (src.rev or src.dirtyRev or "00000000");

  # Pin GCC/CLang versions
  stdenv = if pkgs.stdenv.isLinux then pkgs.gcc13Stdenv else pkgs.clang16Stdenv;

in stdenv.mkDerivation {
  pname = "logos-storage-nim";
  version = "${version}-${revision}";

  inherit src;

    # Disable CPU optimizations that make binary not portable.
  env = {
    NIMFLAGS = "-d:disableMarchNative";
  };

  makeFlags = targets ++ [
    "V=${toString verbosity}"
    # Built from nimbus-build-system via flake.
    "USE_SYSTEM_NIM=1"
  ];

  # Dependencies that should exist in the runtime environment.
  buildInputs = with pkgs; [ openssl gmp ];

  # Dependencies that should only exist in the build environment.
  nativeBuildInputs = let
    # Fix for Nim compiler calling 'git rev-parse' and 'lsb_release'.
    fakeGit = writeScriptBin "git" "echo ${version}";
  in with pkgs; [ nim cmake which fakeGit ]
    ++ lib.optionals stdenv.isLinux [ lsb-release ]
    ++ lib.optionals stdenv.isDarwin [ darwin.cctools ];

  configurePhase = ''
    # Avoid Nim cache permission errors.
    export XDG_CACHE_HOME=$TMPDIR
    patchShebangs . vendor/nimbus-build-system > /dev/null
    make nimbus-build-system-paths
  '';

  installPhase = ''
    if [ -f build/storage ]; then
      mkdir -p $out/bin
      cp build/storage $out/bin/
    else
      mkdir -p $out/lib $out/include
      cp build/libstorage* $out/lib/
      cp library/libstorage.h $out/include/
    fi
  '';

  meta = with pkgs.lib; {
    description = "Logos Storage storage system";
    homepage = "https://github.com/logos-storage/logos-storage-nim";
    license = licenses.mit;
    platforms = stableSystems;
  };
}
