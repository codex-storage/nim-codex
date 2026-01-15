## Logos Storage
## Copyright (c) 2021 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

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
import ./codex/logutils
import ./codex/units
import ./codex/utils/keyutils
import ./codex/codextypes

export codex, conf, libp2p, chronos, logutils

when isMainModule:
  import std/os
  import pkg/confutils/defs
  import ./codex/utils/fileutils

  logScope:
    topics = "codex"

  when defined(posix):
    import system/ansi_c

  type CodexStatus {.pure.} = enum
    Stopped
    Stopping
    Running

  let config = CodexConf.load(
    version = codexFullVersion,
    envVarsPrefix = "storage",
    secondarySources = proc(
        config: CodexConf, sources: auto
    ) {.gcsafe, raises: [ConfigurationError].} =
      if configFile =? config.configFile:
        sources.addConfigFile(Toml, configFile)
    ,
  )
  config.setupLogging()

  try:
    updateLogLevel(config.logLevel)
  except ValueError as err:
    try:
      stderr.write "Invalid value for --log-level. " & err.msg & "\n"
    except IOError:
      echo "Invalid value for --log-level. " & err.msg
    quit QuitFailure

  config.setupMetrics()

  if not (checkAndCreateDataDir((config.dataDir).string)):
    # We are unable to access/create data folder or data folder's
    # permissions are insecure.
    quit QuitFailure

  if config.prover() and not (checkAndCreateDataDir((config.circuitDir).string)):
    quit QuitFailure

  trace "Data dir initialized", dir = $config.dataDir

  if not (checkAndCreateDataDir((config.dataDir / "repo"))):
    # We are unable to access/create data folder or data folder's
    # permissions are insecure.
    quit QuitFailure

  trace "Repo dir initialized", dir = config.dataDir / "repo"

  var
    state: CodexStatus
    shutdown: Future[void]

  let
    keyPath =
      if isAbsolute(config.netPrivKeyFile):
        config.netPrivKeyFile
      else:
        config.dataDir / config.netPrivKeyFile

    privateKey = setupKey(keyPath).expect("Should setup private key!")
    server =
      try:
        CodexServer.new(config, privateKey)
      except Exception as exc:
        error "Failed to start Logos Storage", msg = exc.msg
        quit QuitFailure

  ## Ctrl+C handling
  proc doShutdown() =
    shutdown = server.shutdown()
    state = CodexStatus.Stopping

    notice "Stopping Logos Storage"

  proc controlCHandler() {.noconv.} =
    when defined(windows):
      # workaround for https://github.com/nim-lang/Nim/issues/4057
      try:
        setupForeignThreadGc()
      except Exception as exc:
        raiseAssert exc.msg
        # shouldn't happen
    notice "Shutting down after having received SIGINT"

    doShutdown()

  try:
    setControlCHook(controlCHandler)
  except Exception as exc: # TODO Exception
    warn "Cannot set ctrl-c handler", msg = exc.msg

  # equivalent SIGTERM handler
  when defined(posix):
    proc SIGTERMHandler(signal: cint) {.noconv.} =
      notice "Shutting down after having received SIGTERM"

      doShutdown()

    c_signal(ansi_c.SIGTERM, SIGTERMHandler)

  try:
    waitFor server.start()
  except CatchableError as error:
    error "Logos Storage failed to start", error = error.msg
    # XXX ideally we'd like to issue a stop instead of quitting cold turkey,
    #   but this would mean we'd have to fix the implementation of all
    #   services so they won't crash if we attempt to stop them before they
    #   had a chance to start (currently you'll get a SISGSEV if you try to).
    quit QuitFailure

  state = CodexStatus.Running
  while state == CodexStatus.Running:
    try:
      # poll chronos
      chronos.poll()
    except Exception as exc:
      error "Unhandled exception in async proc, aborting", msg = exc.msg
      quit QuitFailure

  try:
    # signal handlers guarantee that the shutdown Future will
    # be assigned before state switches to Stopping
    waitFor shutdown
  except CatchableError as error:
    error "Logos Storage didn't shutdown correctly", error = error.msg
    quit QuitFailure

  notice "Exited Storage"
