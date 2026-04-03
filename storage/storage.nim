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
import ./storagetypes
import ./logutils
import ./nat

logScope:
  topics = "storage node"

type
  StorageServer* = ref object
    config: StorageConf
    restServer: RestServerRef
    storageNode: StorageNodeRef
    repoStore: RepoStore
    maintenance: BlockMaintainer
    taskpool: Taskpool
    isStarted: bool

  StoragePrivateKey* = libp2p.PrivateKey # alias

func config*(self: StorageServer): StorageConf =
  return self.config

func node*(self: StorageServer): StorageNodeRef =
  return self.storageNode

func repoStore*(self: StorageServer): RepoStore =
  return self.repoStore

proc start*(s: StorageServer) {.async.} =
  if s.isStarted:
    warn "Storage server already started, skipping"
    return

  trace "Starting Storage node", config = $s.config
  await s.repoStore.start()

  s.maintenance.start()

  await s.storageNode.switch.start()

  let (announceAddrs, discoveryAddrs) = nattedAddress(
    s.config.nat, s.storageNode.switch.peerInfo.addrs, s.config.discoveryPort
  )

  s.storageNode.discovery.updateAnnounceRecord(announceAddrs)
  s.storageNode.discovery.updateDhtRecord(discoveryAddrs)

  await s.storageNode.start()

  if s.restServer != nil:
    s.restServer.start()

  s.isStarted = true

proc stop*(s: StorageServer) {.async.} =
  if not s.isStarted:
    warn "Storage is not started"
    return

  notice "Stopping Storage node"

  var futures = @[
    s.storageNode.switch.stop(),
    s.storageNode.stop(),
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

proc close*(s: StorageServer) {.async.} =
  var futures =
    @[s.storageNode.close(), s.repoStore.close(), s.storageNode.discovery.close()]

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

  proc noOutput(logLevel: LogLevel, msg: LogOutputStr) =
    discard

  # If a log file was assigned, clear the `fileFlush` proc to ensure a clean
  # state for future restarts.
  # Without this manual cleanup, the old writer remains active in the global stream.
  # When `setupLogging` is called again during a restart, the GC might trigger
  # after the new context is created, destroying the newly assigned writer and
  # leaving it silently capturing a `None` value. This results in missing log files.
  defaultChroniclesStream.outputs[2].writer = noOutput

proc shutdown*(server: StorageServer) {.async.} =
  await server.stop()
  await server.close()

proc new*(
    T: type StorageServer, config: StorageConf, privateKey: StoragePrivateKey
): StorageServer =
  ## create StorageServer including setting up datastore, repostore, etc
  let listenMultiAddr = getMultiAddrWithIpAndTcpPort(config.listenIp, config.listenPort)

  let switch = SwitchBuilder
    .new()
    .withPrivateKey(privateKey)
    .withAddresses(@[listenMultiAddr])
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

  let discoveryDir = config.dataDir / StorageDhtNamespace

  if io2.createPath(discoveryDir).isErr:
    trace "Unable to create discovery directory for block store",
      discoveryDir = discoveryDir
    raise (ref Defect)(
      msg: "Unable to create discovery directory for block store: " & discoveryDir
    )

  let providersPath = config.dataDir / StorageDhtProvidersNamespace
  let discoveryStoreRes = LevelDbDatastore.new(providersPath)
  if discoveryStoreRes.isErr:
    error "Failed to initialize discovery datastore",
      path = providersPath, err = discoveryStoreRes.error.msg

  let
    discoveryStore =
      Datastore(discoveryStoreRes.expect("Should create discovery datastore!"))

    discovery = Discovery.new(
      switch.peerInfo.privateKey,
      announceAddrs = @[listenMultiAddr],
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
      metaDs = LevelDbDatastore.new(config.dataDir / StorageMetaNamespace).expect(
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

    storageNode = StorageNodeRef.new(
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
        storageNode.initRestApi(config, repoStore, config.apiCorsAllowedOrigin),
        initTAddress(config.apiBindAddress.get(), config.apiPort),
        bufferSize = (1024 * 64),
        maxRequestBodySize = int.high,
      )
      .expect("Should create rest server!")

  switch.mount(network)

  StorageServer(
    config: config,
    storageNode: storageNode,
    restServer: restServer,
    repoStore: repoStore,
    maintenance: maintenance,
    taskPool: taskPool,
  )
