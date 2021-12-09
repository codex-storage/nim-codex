## Nim-Dagger
## Copyright (c) 2021 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import std/sequtils

when defined(posix):
  import system/ansi_c

import pkg/chronicles
import pkg/chronos
import pkg/presto
import pkg/libp2p
import pkg/confutils

import ./node
import ./conf
import ./rng
import ./rest/api
import ./stores/memorystore

type
  DaggerServer = ref object
    runHandle: Future[void]
    config: DaggerConf
    restServer: RestServerRef
    daggerNode: DaggerNodeRef

proc run(s: DaggerServer) {.async.} =
  s.restServer.start()
  await s.daggerNode.start()

  s.runHandle = newFuture[void]()
  await s.runHandle
  await allFuturesThrowing(
    s.restServer.stop(), s.daggerNode.stop())

proc shutdown(s: DaggerServer) =
  s.runHandle.complete()

proc new(T: type DaggerServer, config: DaggerConf): T =
  let
    switch = SwitchBuilder
    .new()
    .withAddresses(config.listenAddrs)
    .withRng(Rng.instance())
    .withNoise()
    .withMplex(5.minutes, 5.minutes)
    .withMaxConnections(config.maxPeers)
    .withAgentVersion(config.agentString)
    .withTcpTransport({ServerFlags.ReuseAddr})
    .build()

  let
    store = MemoryStore.new()
    daggerNode = DaggerNodeRef.new(switch, store, config)
    restServer = RestServerRef.new(
      daggerNode.initRestApi(),
      initTAddress("127.0.0.1" , config.apiPort),
      bufferSize = (1024 * 64),
      maxRequestBodySize = int.high)
      .tryGet()

  T(
    config: config,
    daggerNode: daggerNode,
    restServer: restServer)

let
  config = DaggerConf.load()

case config.cmd:
of StartUpCommand.noCommand:
  let server = DaggerServer.new(config)

  ## Ctrl+C handling
  proc controlCHandler() {.noconv.} =
    when defined(windows):
      # workaround for https://github.com/nim-lang/Nim/issues/4057
      try:
        setupForeignThreadGc()
      except Exception as exc: raiseAssert exc.msg # shouldn't happen
    notice "Shutting down after having received SIGINT"
    server.shutdown()

  try:
    setControlCHook(controlCHandler)
  except Exception as exc: # TODO Exception
    warn "Cannot set ctrl-c handler", msg = exc.msg

  # equivalent SIGTERM handler
  when defined(posix):
    proc SIGTERMHandler(signal: cint) {.noconv.} =
      notice "Shutting down after having received SIGTERM"
      server.shutdown()

    c_signal(SIGTERM, SIGTERMHandler)

  waitFor server.run()
of StartUpCommand.initNode:
  discard
