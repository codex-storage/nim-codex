mode = ScriptMode.Verbose

version = "0.1.0"
author = "Dagger Team"
description = "p2p data durability engine"
license = "MIT"
binDir = "build"
srcDir = "."

requires "nim >= 1.2.0",
         "asynctest >= 0.3.0 & < 0.4.0",
         "bearssl >= 0.1.4",
         "chronicles >= 0.7.2",
         "chronos >= 2.5.2",
         "confutils",
         "ethers >= 0.1.3 & < 0.2.0",
         "libbacktrace",
         "libp2p",
         "metrics",
         "nimcrypto >= 0.4.1",
         "nitro >= 0.4.0 & < 0.5.0",
         "presto",
         "protobuf_serialization >= 0.2.0 & < 0.3.0",
         "questionable >= 0.9.1 & < 0.10.0",
         "secp256k1",
         "stew",
         "upraises >= 0.1.0 & < 0.2.0"

when declared(namedBin):
  namedBin = {
    "dagger/dagger": "dagger"
  }.toTable()

### Helper functions
proc buildBinary(name: string, srcDir = "./", params = "", lang = "c") =
  if not dirExists "build":
    mkDir "build"
  # allow something like "nim nimbus --verbosity:0 --hints:off nimbus.nims"
  var extra_params = params
  for i in 2..<paramCount():
    extra_params &= " " & paramStr(i)
  exec "nim " & lang & " --out:build/" & name & " " & extra_params & " " & srcDir & name & ".nim"

proc test(name: string, srcDir = "tests/", lang = "c") =
  buildBinary name, srcDir
  exec "build/" & name

task testDagger, "Build & run Dagger tests":
  test "testDagger"

task testContracts, "Build & run Dagger Contract tests":
  test "testContracts"

task test, "Run tests":
  testDaggerTask()

task testAll, "Run all tests":
  testDaggerTask()
  testContractsTask()

task dagger, "build dagger binary":
  buildBinary "dagger"
