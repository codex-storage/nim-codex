mode = ScriptMode.Verbose

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

task build, "build codex binary":
  codexTask()

task test, "Run tests":
  testCodexTask()

task testAll, "Run all tests":
  testCodexTask()
  testContractsTask()
  testIntegrationTask()
