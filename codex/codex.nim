## Logos Storage
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
import std/cpuinfo
import std/net

import pkg/chronos
import pkg/taskpools
import pkg/presto
import pkg/libp2p
import pkg/confutils
import pkg/confutils/defs
import pkg/stew/io2
import pkg/datastore
import pkg/stew/io2

import ./node
import ./conf
import ./rng as random
import ./rest/api
import ./stores
import ./blockexchange
import ./utils/fileutils
import ./discovery
import ./systemclock
import ./utils/addrutils
import ./namespaces
import ./codextypes
import ./logutils
import ./nat

logScope:
  topics = "codex node"

type
  CodexServer* = ref object
    config: CodexConf
    restServer: RestServerRef
    codexNode: CodexNodeRef
    repoStore: RepoStore
    maintenance: BlockMaintainer
    taskpool: Taskpool
    isStarted: bool

  CodexPrivateKey* = libp2p.PrivateKey # alias

func config*(self: CodexServer): CodexConf =
  return self.config

func node*(self: CodexServer): CodexNodeRef =
  return self.codexNode

func repoStore*(self: CodexServer): RepoStore =
  return self.repoStore

proc start*(s: CodexServer) {.async.} =
  if s.isStarted:
    warn "Storage server already started, skipping"
    return

  trace "Starting Storage node", config = $s.config
  await s.repoStore.start()

  s.maintenance.start()

  await s.codexNode.switch.start()

  let (announceAddrs, discoveryAddrs) = nattedAddress(
    s.config.nat, s.codexNode.switch.peerInfo.addrs, s.config.discoveryPort
  )

  s.codexNode.discovery.updateAnnounceRecord(announceAddrs)
  s.codexNode.discovery.updateDhtRecord(discoveryAddrs)

  await s.codexNode.start()

  if s.restServer != nil:
    s.restServer.start()

  s.isStarted = true

proc stop*(s: CodexServer) {.async.} =
  if not s.isStarted:
    warn "Storage is not started"
    return

  notice "Stopping Storage node"

  var futures =
    @[
      s.codexNode.switch.stop(),
      s.codexNode.stop(),
      s.codexNode.discovery.stop(),
      s.repoStore.stop(),
      s.maintenance.stop(),
    ]

  if s.restServer != nil:
    futures.add(s.restServer.stop())

  let res = await noCancel allFinishedFailed[void](futures)

  s.isStarted = false

  if res.failure.len > 0:
    error "Failed to stop Storage node", failures = res.failure.len
    raiseAssert "Failed to stop Storage node"

proc close*(s: CodexServer) {.async.} =
  var futures =
    @[s.codexNode.close(), s.repoStore.close(), s.codexNode.discovery.close()]

  let res = await noCancel allFinishedFailed[void](futures)

  if not s.taskpool.isNil:
    try:
      s.taskpool.shutdown()
    except Exception as exc:
      error "Failed to stop the taskpool", failures = res.failure.len
      raiseAssert("Failure in taskpool shutdown:" & exc.msg)

  if res.failure.len > 0:
    error "Failed to close Storage node", failures = res.failure.len
    raiseAssert "Failed to close Storage node"

proc shutdown*(server: CodexServer) {.async.} =
  await server.stop()
  await server.close()

proc new*(
    T: type CodexServer, config: CodexConf, privateKey: CodexPrivateKey
): CodexServer =
  ## create CodexServer including setting up datastore, repostore, etc
  let switch = SwitchBuilder
    .new()
    .withPrivateKey(privateKey)
    .withAddresses(config.listenAddrs)
    .withRng(random.Rng.instance())
    .withNoise()
    .withMplex(5.minutes, 5.minutes)
    .withMaxConnections(config.maxPeers)
    .withAgentVersion(config.agentString)
    .withSignedPeerRecord(true)
    .withTcpTransport({ServerFlags.ReuseAddr, ServerFlags.TcpNoDelay})
    .build()

  var
    cache: CacheStore = nil
    taskPool: Taskpool

  try:
    if config.numThreads == ThreadCount(0):
      taskPool = Taskpool.new(numThreads = min(countProcessors(), 16))
    else:
      taskPool = Taskpool.new(numThreads = int(config.numThreads))
    info "Threadpool started", numThreads = taskPool.numThreads
  except CatchableError as exc:
    raiseAssert("Failure in taskPool initialization:" & exc.msg)

  if config.cacheSize > 0'nb:
    cache = CacheStore.new(cacheSize = config.cacheSize)
    ## Is unused?

  let discoveryDir = config.dataDir / CodexDhtNamespace

  if io2.createPath(discoveryDir).isErr:
    trace "Unable to create discovery directory for block store",
      discoveryDir = discoveryDir
    raise (ref Defect)(
      msg: "Unable to create discovery directory for block store: " & discoveryDir
    )

  let providersPath = config.dataDir / CodexDhtProvidersNamespace
  let discoveryStoreRes = LevelDbDatastore.new(providersPath)
  if discoveryStoreRes.isErr:
    error "Failed to initialize discovery datastore",
      path = providersPath, err = discoveryStoreRes.error.msg

  let
    discoveryStore =
      Datastore(discoveryStoreRes.expect("Should create discovery datastore!"))

    discovery = Discovery.new(
      switch.peerInfo.privateKey,
      announceAddrs = config.listenAddrs,
      bindPort = config.discoveryPort,
      bootstrapNodes = config.bootstrapNodes,
      store = discoveryStore,
    )

    network = BlockExcNetwork.new(switch)

    repoData =
      case config.repoKind
      of repoFS:
        Datastore(
          FSDatastore.new($config.dataDir, depth = 5).expect(
            "Should create repo file data store!"
          )
        )
      of repoSQLite:
        Datastore(
          SQLiteDatastore.new($config.dataDir).expect(
            "Should create repo SQLite data store!"
          )
        )
      of repoLevelDb:
        Datastore(
          LevelDbDatastore.new($config.dataDir).expect(
            "Should create repo LevelDB data store!"
          )
        )

    repoStore = RepoStore.new(
      repoDs = repoData,
      metaDs = LevelDbDatastore.new(config.dataDir / CodexMetaNamespace).expect(
          "Should create metadata store!"
        ),
      quotaMaxBytes = config.storageQuota,
      blockTtl = config.blockTtl,
    )

    maintenance = BlockMaintainer.new(
      repoStore,
      interval = config.blockMaintenanceInterval,
      numberOfBlocksPerInterval = config.blockMaintenanceNumberOfBlocks,
    )

    peerStore = PeerCtxStore.new()
    pendingBlocks = PendingBlocksManager.new(retries = config.blockRetries)
    advertiser = Advertiser.new(repoStore, discovery)
    blockDiscovery =
      DiscoveryEngine.new(repoStore, peerStore, network, discovery, pendingBlocks)
    engine = BlockExcEngine.new(
      repoStore, network, blockDiscovery, advertiser, peerStore, pendingBlocks
    )
    store = NetworkStore.new(engine, repoStore)

    codexNode = CodexNodeRef.new(
      switch = switch,
      networkStore = store,
      engine = engine,
      discovery = discovery,
      taskPool = taskPool,
    )

  var restServer: RestServerRef = nil

  if config.apiBindAddress.isSome:
    restServer = RestServerRef
      .new(
        codexNode.initRestApi(config, repoStore, config.apiCorsAllowedOrigin),
        initTAddress(config.apiBindAddress.get(), config.apiPort),
        bufferSize = (1024 * 64),
        maxRequestBodySize = int.high,
      )
      .expect("Should create rest server!")

  switch.mount(network)

  CodexServer(
    config: config,
    codexNode: codexNode,
    restServer: restServer,
    repoStore: repoStore,
    maintenance: maintenance,
    taskPool: taskPool,
  )
