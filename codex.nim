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
import pkg/questionable
import pkg/confutils
import pkg/confutils/defs
import pkg/confutils/std/net
import pkg/confutils/toml/defs as confTomlDefs
import pkg/confutils/toml/std/net as confTomlNet
import pkg/confutils/toml/std/uri as confTomlUri
import pkg/toml_serialization
import pkg/libp2p

import ./codex/conf
import ./codex/codex
import ./codex/units
import ./codex/utils/keyutils
import ./codex/utils/asyncprofiler

export codex, conf, libp2p, chronos, chronicles

when isMainModule:
  import std/sequtils
  import std/os
  import pkg/confutils/defs
  import ./codex/utils/fileutils

  logScope:
    topics = "codex"

  when defined(posix):
    import system/ansi_c

  type
    CodexStatus {.pure.} = enum
      Stopped,
      Stopping,
      Running

  let config = CodexConf.load(
    version = codexFullVersion,
    envVarsPrefix = "codex",
    secondarySources = proc (config: CodexConf, sources: auto) =
            if configFile =? config.configFile:
              sources.addConfigFile(Toml, configFile)
  )
  config.setupLogging()
  config.setupMetrics()

  # TODO this should not be here, but currently can't have it in setupMetrics
  #   or we get a circular import.
  when chronosProfiling:
    enableProfiling()
    AsyncProfilerInfo.initDefault(k = config.profilerMaxMetrics)

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

    if not(checkAndCreateDataDir((config.dataDir / "repo"))):
      # We are unable to access/create data folder or data folder's
      # permissions are insecure.
      quit QuitFailure

    trace "Repo dir initialized", dir = config.dataDir / "repo"

    var
      state: CodexStatus
      pendingFuts: seq[Future[void]]

    let
      keyPath =
        if isAbsolute(config.netPrivKeyFile):
          config.netPrivKeyFile
        else:
          config.dataDir / config.netPrivKeyFile

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

      pendingFuts.add(server.stop())
      state = CodexStatus.Stopping

      notice "Stopping Codex"

    try:
      setControlCHook(controlCHandler)
    except Exception as exc: # TODO Exception
      warn "Cannot set ctrl-c handler", msg = exc.msg

    # equivalent SIGTERM handler
    when defined(posix):
      proc SIGTERMHandler(signal: cint) {.noconv.} =
        notice "Shutting down after having received SIGTERM"

        pendingFuts.add(server.stop())
        state = CodexStatus.Stopping

        notice "Stopping Codex"

      c_signal(ansi_c.SIGTERM, SIGTERMHandler)

    pendingFuts.add(server.start())

    state = CodexStatus.Running
    while state == CodexStatus.Running:
      # poll chronos
      chronos.poll()

    # wait fot futures to finish
    let res = waitFor allFinished(pendingFuts)
    state = CodexStatus.Stopped

    if res.anyIt( it.failed ):
      error "Codex didn't shutdown correctly"
      quit QuitFailure

    notice "Exited codex"

  of StartUpCommand.initNode:
    discard
