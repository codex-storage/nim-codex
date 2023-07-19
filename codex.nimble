mode = ScriptMode.Verbose

version = "0.1.0"
author = "Codex Team"
description = "p2p data durability engine"
license = "MIT"
binDir = "build"
srcDir = "."

requires "nim >= 1.2.0"
requires "asynctest >= 0.3.2 & < 0.4.0"
requires "bearssl >= 0.1.4"
requires "chronicles >= 0.7.2"
requires "chronos >= 2.5.2"
requires "confutils"
requires "ethers >= 0.2.4 & < 0.3.0"
requires "libbacktrace"
requires "libp2p"
requires "metrics"
requires "nimcrypto >= 0.4.1"
requires "nitro >= 0.5.1 & < 0.6.0"
requires "presto"
requires "protobuf_serialization >= 0.2.0 & < 0.3.0"
requires "questionable >= 0.10.6 & < 0.11.0"
requires "secp256k1"
requires "stew"
requires "upraises >= 0.1.0 & < 0.2.0"
requires "toml_serialization"
requires "https://github.com/status-im/lrucache.nim#1.2.2"
requires "leopard >= 0.1.0 & < 0.2.0"
requires "blscurve"
requires "libp2pdht"
requires "eth"

when declared(namedBin):
  namedBin = {
    "codex/codex": "codex"
  }.toTable()

when not declared(getPathsClause):
  proc getPathsClause(): string = ""

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

  exec "nim " & getPathsClause() & " " & lang & " --out:build/" & name & " " & extra_params & " " & srcDir & name & ".nim"

proc test(name: string, srcDir = "tests/", params = "", lang = "c") =
  buildBinary name, srcDir, params
  exec "build/" & name

task codex, "build codex binary":
  buildBinary "codex", params = "-d:chronicles_runtime_filtering -d:chronicles_log_level=TRACE"

task testCodex, "Build & run Codex tests":
  test "testCodex", params = "-d:codex_enable_proof_failures=true"

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
