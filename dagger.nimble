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

import os

const build_opts =
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

const common_opts =
  " --define:ssl" &
  " --threads:on" &
  " --tlsEmulation:off"

const chronos_preferred =
  " --path:\"" &
  staticExec("nimble path chronos --silent").parentDir /
  "chronos-#export-selector-field\""

task localstore, "Build localstore experiment":
  var commands = [
    "nim c" &
    build_opts &
    common_opts &
    chronos_preferred &
    " experiments/localstore.nim",
    "experiments/localstore"
  ]
  for command in commands:
    exec command
