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
import ./codex/utils/keyutils

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

    if config.nat == ValidIpAddress.init(IPv4_any()):
      error "`--nat` cannot be set to the any (`0.0.0.0`) address"
      quit QuitFailure

    if config.nat == ValidIpAddress.init("127.0.0.1"):
      warn "`--nat` is set to loopback, your node wont properly announce over the DHT"

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

    let
      keyPath =
        if isAbsolute(string config.netPrivKeyFile):
          string config.netPrivKeyFile
        else:
          string config.dataDir / string config.netPrivKeyFile

      privateKey = setupKey(keyPath).expect("Should setup private key!")
      server = CodexServer.new(config, privateKey)

    ## Ctrl+C handling
    proc controlCHandler() {.noconv.} =
      when defined(windows):
        # workaround for https://github.com/nim-lang/Nim/issues/4057
        try:
          setupForeignThreadGc()
        except Exception as exc: raiseAssert exc.msg # shouldn't happen
      notice "Shutting down after having received SIGINT"
      waitFor server.stop()

    setControlCHook(controlCHandler)

    # equivalent SIGTERM handler
    when defined(posix):
      proc SIGTERMHandler(signal: cint) {.noconv.} =
        notice "Shutting down after having received SIGTERM"
        waitFor server.stop()
        notice "Stopped Codex"

      c_signal(ansi_c.SIGTERM, SIGTERMHandler)

    waitFor server.start()
    notice "Exited codex"

  of StartUpCommand.initNode:
    discard
