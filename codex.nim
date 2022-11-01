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

import ./codex/conf
import ./codex/codex

export codex, conf, libp2p, chronos, chronicles

when isMainModule:
  import std/os

  import pkg/confutils/defs

  import ./codex/utils/fileutils

  logScope:
    topics = "codex"

  when defined(posix):
    import system/ansi_c

  let config = CodexConf.load(
    version = codexFullVersion
  )
  config.setupLogging()
  config.setupMetrics()

  case config.cmd:
  of StartUpCommand.noCommand:

    if not(checkAndCreateDataDir((config.dataDir).string)):
      # We are unable to access/create data folder or data folder's
      # permissions are insecure.
      quit QuitFailure

    trace "Data dir initialized", dir = $config.dataDir

    if not(checkAndCreateDataDir((config.dataDir / "repo").string)):
      # We are unable to access/create data folder or data folder's
      # permissions are insecure.
      quit QuitFailure

    trace "Repo dir initialized", dir = config.dataDir / "repo"

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
    discard
