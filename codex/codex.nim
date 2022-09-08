## Nim-Codex
## Copyright (c) 2021 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import std/sequtils
import std/os
import std/sugar

import pkg/chronicles
import pkg/chronos
import pkg/presto
import pkg/libp2p
import pkg/confutils
import pkg/confutils/defs
import pkg/nitro
import pkg/stew/io2
import pkg/stew/shims/net as stewnet

import ./node
import ./conf
import ./rng
import ./rest/api
import ./stores
import ./blockexchange
import ./utils/fileutils
import ./erasure
import ./discovery
import ./contracts

type
  CodexServer* = ref object
    runHandle: Future[void]
    config: CodexConf
    restServer: RestServerRef
    codexNode: CodexNodeRef

proc start*(s: CodexServer) {.async.} =
  s.restServer.start()
  await s.codexNode.start()

  s.runHandle = newFuture[void]()
  await s.runHandle

proc stop*(s: CodexServer) {.async.} =
  await allFuturesThrowing(
    s.restServer.stop(), s.codexNode.stop())

  s.runHandle.complete()

proc new(_: type ContractInteractions, config: CodexConf): ?ContractInteractions =
  if not config.persistence:
    if config.ethAccount.isSome:
      warn "Ethereum account was set, but persistence is not enabled"
    return

  without account =? config.ethAccount:
    error "Persistence enabled, but no Ethereum account was set"
    quit QuitFailure

  if deployment =? config.ethDeployment:
    ContractInteractions.new(config.ethProvider, account, deployment)
  else:
    ContractInteractions.new(config.ethProvider, account)

proc new*(T: type CodexServer, config: CodexConf): T =

  const SafePermissions = {UserRead, UserWrite}
  let
    privateKey =
      if config.netPrivKeyFile == "random":
        PrivateKey.random(Rng.instance()[]).get()
      else:
        let path =
          if config.netPrivKeyFile.isAbsolute:
            config.netPrivKeyFile
          else:
            config.dataDir / config.netPrivKeyFile

        if path.fileAccessible({AccessFlags.Find}):
          info "Found a network private key"

          if path.getPermissionsSet().get() != SafePermissions:
            warn "The network private key file is not safe, aborting"
            quit QuitFailure

          PrivateKey.init(path.readAllBytes().expect("accessible private key file")).
            expect("valid private key file")
        else:
          info "Creating a private key and saving it"
          let
            res = PrivateKey.random(Rng.instance()[]).get()
            bytes = res.getBytes().get()

          path.writeFile(bytes, SafePermissions.toInt()).expect("writing private key file")

          PrivateKey.init(bytes).expect("valid key bytes")

  let
    addresses =
      config.listenPorts.mapIt(MultiAddress.init("/ip4/" & $config.listenIp & "/tcp/" & $(it.int)).tryGet()) &
        @[MultiAddress.init("/ip4/" & $config.listenIp & "/udp/" & $(config.discoveryPort.int)).tryGet()]
    switch = SwitchBuilder
    .new()
    .withPrivateKey(privateKey)
    .withAddresses(addresses)
    .withRng(Rng.instance())
    .withNoise()
    .withMplex(5.minutes, 5.minutes)
    .withMaxConnections(config.maxPeers)
    .withAgentVersion(config.agentString)
    .withSignedPeerRecord(true)
    .withTcpTransport({ServerFlags.ReuseAddr})
    .build()

  var
    cache: CacheStore

  if config.cacheSize > 0:
    cache = CacheStore.new(cacheSize = config.cacheSize * MiB)

  let
    discoveryBootstrapNodes = config.bootstrapNodes
    blockDiscovery = Discovery.new(
        switch.peerInfo,
        discoveryPort = config.discoveryPort,
        bootstrapNodes = discoveryBootstrapNodes
      )

    wallet = WalletRef.new(EthPrivateKey.random())
    network = BlockExcNetwork.new(switch)
    repoDir = config.dataDir / "repo"

  if io2.createPath(repoDir).isErr:
    trace "Unable to create data directory for block store", dataDir = repoDir
    raise (ref Defect)(
      msg: "Unable to create data directory for block store: " & repoDir)

  let
    localStore = FSStore.new(repoDir, cache = cache)
    peerStore = PeerCtxStore.new()
    pendingBlocks = PendingBlocksManager.new()
    discovery = DiscoveryEngine.new(localStore, peerStore, network, blockDiscovery, pendingBlocks)
    engine = BlockExcEngine.new(localStore, wallet, network, discovery, peerStore, pendingBlocks)
    store = NetworkStore.new(engine, localStore)
    erasure = Erasure.new(store, leoEncoderProvider, leoDecoderProvider)
    contracts = ContractInteractions.new(config)
    codexNode = CodexNodeRef.new(switch, store, engine, erasure, blockDiscovery, contracts)
    restServer = RestServerRef.new(
      codexNode.initRestApi(config),
      initTAddress("127.0.0.1" , config.apiPort),
      bufferSize = (1024 * 64),
      maxRequestBodySize = int.high)
      .tryGet()

  switch.mount(network)
  T(
    config: config,
    codexNode: codexNode,
    restServer: restServer,
    )
