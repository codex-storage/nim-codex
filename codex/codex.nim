## Nim-Codex
## Copyright (c) 2021 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import std/sequtils
import std/strutils
import std/os
import std/tables

import pkg/chronicles
import pkg/chronos
import pkg/presto
import pkg/libp2p
import pkg/confutils
import pkg/confutils/defs
import pkg/nitro
import pkg/stew/io2
import pkg/stew/shims/net as stewnet
import pkg/datastore
import pkg/ethers except Rng

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
import ./contracts/clock
import ./contracts/deployment
import ./utils/addrutils
import ./namespaces

logScope:
  topics = "codex node"

type
  CodexServer* = ref object
    runHandle: Future[void]
    config: CodexConf
    restServer: RestServerRef
    codexNode: CodexNodeRef
    repoStore: RepoStore
    maintenance: BlockMaintainer

  CodexPrivateKey* = libp2p.PrivateKey # alias
  EthWallet = ethers.Wallet

proc bootstrapInteractions(
    config: CodexConf,
    repo: RepoStore
): Future[Contracts] {.async.} =
  ## bootstrap interactions and return contracts
  ## using clients, hosts, validators pairings
  ##

  if not config.persistence and not config.validator:
    if config.ethAccount.isSome or config.ethPrivateKey.isSome:
      warn "Ethereum account was set, but neither persistence nor validator is enabled"
    return

  if not config.ethAccount.isSome and not config.ethPrivateKey.isSome:
    if config.persistence:
      error "Persistence enabled, but no Ethereum account was set"
    if config.validator:
      error "Validator enabled, but no Ethereum account was set"
    quit QuitFailure

  let provider = JsonRpcProvider.new(config.ethProvider)
  var signer: Signer
  if account =? config.ethAccount:
    signer = provider.getSigner(account)
  elif keyFile =? config.ethPrivateKey:
    without isSecure =? checkSecureFile(keyFile):
      error "Could not check file permissions: does Ethereum private key file exist?"
      quit QuitFailure
    if not isSecure:
      error "Ethereum private key file does not have safe file permissions"
      quit QuitFailure
    without key =? keyFile.readAllChars():
      error "Unable to read Ethereum private key file"
      quit QuitFailure
    without wallet =? EthWallet.new(key.strip(), provider):
      error "Invalid Ethereum private key in file"
      quit QuitFailure
    signer = wallet

  let deploy = Deployment.new(provider, config)
  without marketplaceAddress =? await deploy.address(Marketplace):
    error "No Marketplace address was specified or there is no known address for the current network"
    quit QuitFailure

  let marketplace = Marketplace.new(marketplaceAddress, signer)
  let market = OnChainMarket.new(marketplace)
  let clock = OnChainClock.new(provider)

  var client: ?ClientInteractions
  var host: ?HostInteractions
  var validator: ?ValidatorInteractions

  if config.persistence:
    # This is used for simulation purposes. Normal nodes won't be compiled with this flag
    # and hence the proof failure will always be 0.
    when codex_enable_proof_failures:
      let proofFailures = config.simulateProofFailures
      if proofFailures > 0:
        warn "Enabling proof failure simulation!"
    else:
      let proofFailures = 0
      if config.simulateProofFailures > 0:
        warn "Proof failure simulation is not enabled for this build! Configuration ignored"

    let purchasing = Purchasing.new(market, clock)
    let sales = Sales.new(market, clock, repo, proofFailures)
    client = some ClientInteractions.new(clock, purchasing)
    host = some HostInteractions.new(clock, sales)
  if config.validator:
    let validation = Validation.new(clock, market, config.validatorMaxSlots)
    validator = some ValidatorInteractions.new(clock, validation)

  return (client, host, validator)

proc start*(s: CodexServer) {.async.} =
  notice "Starting codex node"

  await s.repoStore.start()
  s.maintenance.start()

  await s.codexNode.switch.start()

  let
    # TODO: Can't define these as constants, pity
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

  s.codexNode.contracts = await bootstrapInteractions(s.config, s.repoStore)
  await s.codexNode.start()
  s.restServer.start()

  s.runHandle = newFuture[void]("codex.runHandle")
  await s.runHandle

proc stop*(s: CodexServer) {.async.} =
  notice "Stopping codex node"

  await allFuturesThrowing(
    s.restServer.stop(),
    s.codexNode.switch.stop(),
    s.codexNode.stop(),
    s.repoStore.stop(),
    s.maintenance.stop())

  s.runHandle.complete()

proc new*(
    T: type CodexServer,
    config: CodexConf,
    privateKey: CodexPrivateKey
): CodexServer =
  ## create CodexServer including setting up datastore, repostore, etc
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

  if config.cacheSize > 0'nb:
    cache = CacheStore.new(cacheSize = config.cacheSize)
    ## Is unused?

  let
    discoveryDir = config.dataDir / CodexDhtNamespace

  if io2.createPath(discoveryDir).isErr:
    trace "Unable to create discovery directory for block store", discoveryDir = discoveryDir
    raise (ref Defect)(
      msg: "Unable to create discovery directory for block store: " & discoveryDir)

  let
    discoveryStore = Datastore(
      SQLiteDatastore.new(config.dataDir / CodexDhtProvidersNamespace)
      .expect("Should create discovery datastore!"))

    discovery = Discovery.new(
      switch.peerInfo.privateKey,
      announceAddrs = config.listenAddrs,
      bindIp = config.discoveryIp,
      bindPort = config.discoveryPort,
      bootstrapNodes = config.bootstrapNodes,
      store = discoveryStore)

    wallet = WalletRef.new(EthPrivateKey.random())
    network = BlockExcNetwork.new(switch)

    treeReader = TreeReader.new()

    repoData = case config.repoKind
                of repoFS: Datastore(FSDatastore.new($config.dataDir, depth = 5)
                  .expect("Should create repo file data store!"))
                of repoSQLite: Datastore(SQLiteDatastore.new($config.dataDir)
                  .expect("Should create repo SQLite data store!"))

    repoStore = RepoStore.new(
      repoDs = repoData,
      metaDs = SQLiteDatastore.new(config.dataDir / CodexMetaNamespace)
        .expect("Should create meta data store!"),
      quotaMaxBytes = config.storageQuota.uint,
      blockTtl = config.blockTtl)

    maintenance = BlockMaintainer.new(
      repoStore,
      interval = config.blockMaintenanceInterval,
      numberOfBlocksPerInterval = config.blockMaintenanceNumberOfBlocks)

    peerStore = PeerCtxStore.new()
    pendingBlocks = PendingBlocksManager.new()
    blockDiscovery = DiscoveryEngine.new(repoStore, peerStore, network, discovery, pendingBlocks)
    engine = BlockExcEngine.new(repoStore, wallet, network, blockDiscovery, peerStore, pendingBlocks)
    store = NetworkStore.new(engine, repoStore)
    erasure = Erasure.new(store, leoEncoderProvider, leoDecoderProvider)
    codexNode = CodexNodeRef.new(switch, store, engine, erasure, discovery)
    restServer = RestServerRef.new(
      codexNode.initRestApi(config),
      initTAddress(config.apiBindAddress , config.apiPort),
      bufferSize = (1024 * 64),
      maxRequestBodySize = int.high)
      .expect("Should start rest server!")

  switch.mount(network)

  CodexServer(
    config: config,
    codexNode: codexNode,
    restServer: restServer,
    repoStore: repoStore,
    maintenance: maintenance
  )
