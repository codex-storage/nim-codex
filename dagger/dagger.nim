## Nim-Dagger
## Copyright (c) 2021 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import std/sequtils
import std/os

import pkg/chronicles
import pkg/chronos
import pkg/presto
import pkg/libp2p
import pkg/confutils
import pkg/confutils/defs
import pkg/nitro
import pkg/stew/io2

import ./node
import ./conf
import ./rng
import ./rest/api
import ./stores/fsstore
import ./stores/networkstore
import ./blockexchange
import ./utils/fileutils

type
  DaggerServer* = ref object
    runHandle: Future[void]
    config: DaggerConf
    restServer: RestServerRef
    daggerNode: DaggerNodeRef

proc run*(s: DaggerServer) {.async.} =
  s.restServer.start()
  await s.daggerNode.start()

  s.runHandle = newFuture[void]()
  await s.runHandle

proc shutdown*(s: DaggerServer) {.async.} =
  await allFuturesThrowing(
    s.restServer.stop(), s.daggerNode.stop())

  s.runHandle.complete()

proc new*(T: type DaggerServer, config: DaggerConf): T =

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
    wallet = WalletRef.new(EthPrivateKey.random())
    network = BlockExcNetwork.new(switch)
    localStore = FSStore.new(config.dataDir / "repo")
    engine = BlockExcEngine.new(localStore, wallet, network)
    store = NetworkStore.new(engine, localStore)
    daggerNode = DaggerNodeRef.new(switch, store, engine)
    restServer = RestServerRef.new(
      daggerNode.initRestApi(),
      initTAddress("127.0.0.1" , config.apiPort),
      bufferSize = (1024 * 64),
      maxRequestBodySize = int.high)
      .tryGet()

  switch.mount(network)
  T(
    config: config,
    daggerNode: daggerNode,
    restServer: restServer)
