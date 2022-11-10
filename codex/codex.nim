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
import ./utils/keyutils
import ./utils/addrutils

logScope:
  topics = "codex node"

type
  CodexServer* = ref object
    runHandle: Future[void]
    config: CodexConf
    restServer: RestServerRef
    codexNode: CodexNodeRef

  CodexPrivateKey* = libp2p.PrivateKey # alias

proc start*(s: CodexServer) {.async.} =
  s.restServer.start()
  await s.codexNode.start()

  let
    # TODO: Can't define this as constants, pity
    natIpPart = MultiAddress.init("/ip4/" & $s.config.nat & "/")
      .expect("Should create multiaddress")
    anyAddrIp = MultiAddress.init("/ip4/0.0.0.0/")
      .expect("Should create multiaddress")
    loopBackAddrIp = MultiAddress.init("/ip4/127.0.0.1/")
      .expect("Should create multiaddress")

    # announce addresses should be set to bound addresses,
    # but the IP should be mapped to the provided nat ip
    announceAddrs = s.codexNode.switch.peerInfo.addrs.mapIt:
      block:
        let
          listenIPPart = it[multiCodec("ip4")].expect("Should get IP")

        if listenIPPart == anyAddrIp or
          (listenIPPart == loopBackAddrIp and natIpPart != loopBackAddrIp):
          it.remapAddr(s.config.nat.some)
        else:
          it

  s.codexNode.discovery.updateAnnounceRecord(announceAddrs)
  s.codexNode.discovery.updateDhtRecord(s.config.nat, s.config.discoveryPort)

  s.runHandle = newFuture[void]("codex.runHandle")
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

proc new*(T: type CodexServer, config: CodexConf, privateKey: CodexPrivateKey): T =

  let
    switch = SwitchBuilder
    .new()
    .withPrivateKey(privateKey)
    .withAddresses(config.listenAddrs)
    .withRng(Rng.instance())
    .withNoise()
    .withMplex(5.minutes, 5.minutes)
    .withMaxConnections(config.maxPeers)
    .withAgentVersion(config.agentString)
    .withSignedPeerRecord(true)
    .withTcpTransport({ServerFlags.ReuseAddr})
    .build()

  var
    cache: CacheStore = nil

  if config.cacheSize > 0:
    cache = CacheStore.new(cacheSize = config.cacheSize * MiB)

  let
    discoveryStore = Datastore(SQLiteDatastore.new(
      config.dataDir / "dht")
      .expect("Should not fail!"))

    discovery = Discovery.new(
      switch.peerInfo.privateKey,
      announceAddrs = config.listenAddrs,
      bindIp = config.discoveryIp,
      bindPort = config.discoveryPort,
      bootstrapNodes = config.bootstrapNodes,
      store = discoveryStore)

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
    blockDiscovery = DiscoveryEngine.new(localStore, peerStore, network, discovery, pendingBlocks)
    engine = BlockExcEngine.new(localStore, wallet, network, blockDiscovery, peerStore, pendingBlocks)
    store = NetworkStore.new(engine, localStore)
    erasure = Erasure.new(store, leoEncoderProvider, leoDecoderProvider)
    contracts = ContractInteractions.new(config)
    codexNode = CodexNodeRef.new(switch, store, engine, erasure, discovery, contracts)
    restServer = RestServerRef.new(
      codexNode.initRestApi(config),
      initTAddress("127.0.0.1" , config.apiPort),
      bufferSize = (1024 * 64),
      maxRequestBodySize = int.high)
      .expect("Should start rest server!")

  switch.mount(network)
  T(
    config: config,
    codexNode: codexNode,
    restServer: restServer)
