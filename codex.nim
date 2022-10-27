## Nim-Codex
## Copyright (c) 2021 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import pkg/chronicles
import pkg/chronos
import pkg/confutils
import pkg/libp2p
import pkg/toml_serialization
import pkg/json_serialization

import ./codex/conf
import ./codex/codex
import ./codex/utils/serialization

export codex, conf, libp2p, chronos, chronicles

when isMainModule:
  import std/os

  import pkg/confutils/defs

  when defined(posix):
    import system/ansi_c

  let
    config = CodexConf.load(
      version = codexFullVersion,
      secondarySources = proc (config: CodexConf, sources: auto) =
        let
          confFile = if config.confFile.isNone:
              (config.dataDir / ConfFile).changeFileExt("toml")
            else:
              config.confFile.get.changeFileExt("toml")

        if confFile.fileExists():
          sources.addConfigFile(Toml, confFile.InputFile)
    )

  config.setupDataDir()
  config.setupLogging()
  config.setupMetrics()

  case config.cmd:
  of StartUpCommand.noCommand:

    let server = CodexServer.new(config)

    ## Ctrl+C handling
    proc controlCHandler() {.noconv.} =
      when defined(windows):
        # workaround for https://github.com/nim-lang/Nim/issues/4057
        try:
          setupForeignThreadGc()
        except Exception as exc: raiseAssert exc.msg # shouldn't happen
      notice "Shutting down after having received SIGINT"
      waitFor server.stop()

    try:
      setControlCHook(controlCHandler)
    except Exception as exc: # TODO Exception
      warn "Cannot set ctrl-c handler", msg = exc.msg

    # equivalent SIGTERM handler
    when defined(posix):
      proc SIGTERMHandler(signal: cint) {.noconv.} =
        notice "Shutting down after having received SIGTERM"
        waitFor server.stop()

      c_signal(SIGTERM, SIGTERMHandler)

    waitFor server.start()
  of StartUpCommand.initNode:
    let
      confFile = if config.confFile.isSome:
          config.confFile.get.string
        else:
          config.dataDir / ConfFile

    Toml.saveFile(confFile.changeFileExt("toml"), config)
