mode = ScriptMode.Verbose

version = "0.1.0"
author = "Dagger Team"
description = "p2p data durability engine"
license = "MIT"

requires "libp2p#unstable",
         "nimcrypto >= 0.4.1",
         "bearssl >= 0.1.4",
         "chronicles >= 0.7.2",
         "https://github.com/michaelsbradleyjr/nim-chronos.git#export-selector-field",
         "metrics",
         "secp256k1",
         "stew#head",
         "protobufserialization >= 0.2.0 & < 0.3.0",
         "https://github.com/status-im/nim-nitro >= 0.4.0 & < 0.5.0",
         "questionable >= 0.9.1 & < 0.10.0",
         "upraises >= 0.1.0 & < 0.2.0",
         "asynctest >= 0.3.0 & < 0.4.0",
         "https://github.com/status-im/nim-task-runner.git#impl_beta2_nimble"

### Helper functions
proc buildBinary(name: string, srcDir = "./", params = "", lang = "c") =
  if not dirExists "build":
    mkDir "build"
  # allow something like "nim nimbus --verbosity:0 --hints:off nimbus.nims"
  var extra_params = params
  for i in 2..<paramCount():
    extra_params &= " " & paramStr(i)
  exec "nim " & lang & " --out:build/" & name & " " & extra_params & " " & srcDir & name & ".nim"

proc test(name: string, params = "-d:chronicles_log_level=DEBUG", lang = "c") =
  buildBinary name, "tests/", params
  exec "build/" & name

task testAll, "Build & run Waku v1 tests":
  test "testAll", "-d:chronicles_log_level=WARN"

task task_runner_streams, "Build task_runner_streams experiment":
  const
    build_opts =
      when defined(danger) or defined(release):
      (if defined(danger): " --define:danger" else: " --define:release") &
        " --define:strip" &
        " --hints:off" &
        " --opt:size" &
        " --passC:-flto" &
        " --passL:-flto"
      else:
        " --debugger:native" &
        " --define:chronicles_line_numbers" &
        " --define:debug" &
        " --linetrace:on" &
        " --stacktrace:on"

    common_opts =
      " --define:ssl" &
      " --out:build/task_runner_streams" &
      " --threads:on" &
      " --tlsEmulation:off"

    chronicles_log_level {.strdefine.} =
     when defined(danger) or defined(release):
       "INFO"
     else:
       "DEBUG"

    host {.strdefine.} = ""
    maxRequestBodySize {.strdefine.} = ""
    port {.strdefine.} = ""

  var commands = [
    "nim c" &
    build_opts &
    common_opts &
    " --define:chronicles_log_level=" & chronicles_log_level &
    (when host != "": " --define:host=" & host else: "") &
    (when maxRequestBodySize != "": " --define:maxRequestBodySize=" & maxRequestBodySize else: "") &
    (when port != "": " --define:port=" & port else: "") &
    " experiments/task_runner_streams.nim",
    "build/task_runner_streams"
  ]

  for command in commands:
    exec command
