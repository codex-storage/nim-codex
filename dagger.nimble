mode = ScriptMode.Verbose

version = "0.1.0"
author = "Dagger Team"
description = "p2p data durability engine"
license = "MIT"

requires "libp2p#unstable",
         "nimcrypto >= 0.4.1",
         "bearssl >= 0.1.4",
         "chronicles >= 0.7.2",
         "chronos >= 2.5.2",
         "metrics",
         "secp256k1",
         "stew#head",
         "protobufserialization >= 0.2.0 & < 0.3.0",
         "https://github.com/status-im/nim-nitro >= 0.4.0 & < 0.5.0",
         "https://github.com/status-im/nim-ethers >= 0.1.2 & < 0.2.0",
         "questionable >= 0.9.1 & < 0.10.0",
         "upraises >= 0.1.0 & < 0.2.0",
         "asynctest >= 0.3.0 & < 0.4.0"

### Helper functions
proc buildBinary(name: string, srcDir = "./", params = "", lang = "c") =
  if not dirExists "build":
    mkDir "build"
  # allow something like "nim nimbus --verbosity:0 --hints:off nimbus.nims"
  var extra_params = params
  for i in 2..<paramCount():
    extra_params &= " " & paramStr(i)
  exec "nim " & lang & " --out:build/" & name & " " & extra_params & " " & srcDir & name & ".nim"

proc test(name: string, srcDir = "tests/", params = "-d:chronicles_log_level=DEBUG", lang = "c") =
  buildBinary name, srcDir, params
  exec "build/" & name

task testDagger, "Build & run Dagger tests":
  test "testDagger", params = "-d:chronicles_log_level=WARN"

task testContracts, "Build & run Dagger Contract tests":
  test "testContracts", "tests/", "-d:chronicles_log_level=WARN"

task test, "Run all tests":
  testDaggerTask()
  testContractsTask()

task dagger, "build dagger binary":
  buildBinary "dagger"
