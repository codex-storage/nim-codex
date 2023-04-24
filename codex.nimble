mode = ScriptMode.Verbose

version = "0.1.0"
author = "Codex Team"
description = "p2p data durability engine"
license = "MIT"
binDir = "build"
srcDir = "."

requires "nim >= 1.2.0",
         "asynctest >= 0.3.2 & < 0.4.0",
         "bearssl >= 0.1.4",
         "chronicles >= 0.7.2",
         "chronos >= 2.5.2",
         "confutils",
         "ethers >= 0.2.4 & < 0.3.0",
         "libbacktrace",
         "libp2p",
         "metrics",
         "nimcrypto >= 0.4.1",
         "nitro >= 0.5.1 & < 0.6.0",
         "presto",
         "protobuf_serialization >= 0.2.0 & < 0.3.0",
         "questionable >= 0.10.6 & < 0.11.0",
         "secp256k1",
         "stew",
         "upraises >= 0.1.0 & < 0.2.0",
         "https://github.com/status-im/lrucache.nim#1.2.2",
         "leopard >= 0.1.0 & < 0.2.0",
         "blscurve",
         "libp2pdht",
         "eth"

when declared(namedBin):
  namedBin = {
    "codex/codex": "codex"
  }.toTable()

### Helper functions
proc buildBinary(name: string, srcDir = "./", params = "", lang = "c") =
  if not dirExists "build":
    mkDir "build"
  # allow something like "nim nimbus --verbosity:0 --hints:off nimbus.nims"
  var extra_params = params
  when compiles(commandLineParams):
    for param in commandLineParams:
      extra_params &= " " & param
  else:
    for i in 2..<paramCount():
      extra_params &= " " & paramStr(i)


  exec "nim " & lang & " --out:build/" & name & " " & extra_params & " " & srcDir & name & ".nim"

proc test(name: string, srcDir = "tests/", lang = "c") =
  buildBinary name, srcDir
  exec "build/" & name

task codex, "build codex binary":
  buildBinary "codex", params = "-d:chronicles_runtime_filtering -d:chronicles_log_level=TRACE"

task testCodex, "Build & run Codex tests":
  test "testCodex"

task testContracts, "Build & run Codex Contract tests":
  test "testContracts"

task testIntegration, "Run integration tests":
  buildBinary "codex", params = "-d:chronicles_runtime_filtering -d:chronicles_log_level=TRACE -d:codex_enable_proof_failures=true"
  test "testIntegration"

task test, "Run tests":
  testCodexTask()

task testAll, "Run all tests":
  testCodexTask()
  testContractsTask()
  testIntegrationTask()
