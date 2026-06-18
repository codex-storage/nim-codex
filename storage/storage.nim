## Logos Storage
## Copyright (c) 2021 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import std/os
import std/tables
import std/cpuinfo
import std/net
import std/sequtils

import pkg/chronos
import pkg/taskpools
import pkg/presto
import pkg/libp2p
import pkg/libp2p_mix
import pkg/confutils
import pkg/confutils/defs
import pkg/stew/io2
import pkg/datastore
import pkg/stew/io2

import ./node
import ./manifest/protocol
import ./conf
import ./rng as random
import ./rest/api
import ./stores
import ./blockexchange
import ./dht_proxy/handler
import ./utils/fileutils
import ./utils/mixidentity
import ./discovery
import ./utils/addrutils
import ./utils/natutils
import ./namespaces
import ./storagetypes
import ./logutils
import ./nat

logScope:
  topics = "storage node"

type
  StorageServer* = ref object
    config: StorageConf
    logFile*: Option[IoHandle]
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

  if s.config.mixEnabled:
    let
      switch = s.storageNode.switch
      (mixPub, mixPriv) = loadOrGenerateMixKeys(
        string(s.config.dataDir) / "mix-identity"
      ).valueOr:
        raise newException(
          StorageError, "Failed to load or generate Mix keys: " & error.msg
        )
      mixAddr = pickMixCompatibleMultiAddr(switch.peerInfo.addrs).valueOr:
        raise newException(StorageError, "No Mix-compatible address among listen addrs")
      mixNodeInfo = buildMixNodeInfo(
        mixPub, mixPriv, switch.peerInfo.peerId, mixAddr, switch.peerInfo.privateKey
      ).valueOr:
        raise newException(StorageError, "Failed to build Mix node info: " & error.msg)
      relayPool = (
        if s.config.mixPoolJson.len > 0:
          loadRelayPubInfoTableFromJson(s.config.mixPoolJson)
        else:
          loadRelayPubInfoTableFromFile(s.config.mixPool)
      ).valueOr:
        raise newException(StorageError, "Failed to load Mix relay pool: " & error.msg)
      mixProto = MixProtocol.new(mixNodeInfo, switch)

    for info in relayPool.values:
      mixProto.nodePool.add(info)

    mixProto.registerDestReadBehavior(DhtProxyCodec, readLp(MaxLookupResponseBytes))
    await mixProto.start()
    switch.mount(mixProto)

    let dhtProxyProto =
      if cap =? s.config.dhtProxyMaxInFlight:
        DhtProxyProtocol.new(s.storageNode.discovery, maxInFlight = cap)
      else:
        DhtProxyProtocol.new(s.storageNode.discovery)
    await dhtProxyProto.start()
    switch.mount(dhtProxyProto)

    s.storageNode.discovery.mixProto = mixProto

    s.storageNode.engine.network.excludeRelays(relayPool.keys.toSeq)

  let (announceAddrs, discoveryAddrs) = nattedAddress(
    s.config.nat, s.storageNode.switch.peerInfo.addrs, s.config.discoveryPort
  )

  var hasPublicAddr = false
  for announceAddr in announceAddrs:
    let (maybeIp, _) = getAddressAndPort(announceAddr)
    if maybeIp.isSome and maybeIp.get.isGlobalUnicast():
      hasPublicAddr = true
      break

  if not hasPublicAddr:
    warn "Unable to determine a public IP address. This node will only be reachable on a private network."

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

  let res = await noCancel allDone[void](futures)

  s.isStarted = false

  if res.failed.len > 0:
    error "Failed to stop Storage node", failures = res.failed.len
    raise newException(
      StorageError,
      "Failed to stop Storage node: " & res.failed.mapIt(it.error.msg).join(", "),
    )
  if res.cancelled.len > 0:
    warn "Storage node stop was cancelled due to child stop routine(s) being cancelled, child routines cancelled: ",
      cancellations = res.cancelled.len
    raise newException(
      CancelledError,
      "Storage node stop was cancelled due to child stop routine(s) being cancelled, child routines cancelled: " &
        $res.cancelled.len,
    )

proc close*(s: StorageServer) {.async.} =
  var futures =
    @[s.storageNode.close(), s.repoStore.close(), s.storageNode.discovery.close()]

  let res = await noCancel allDone[void](futures)

  if not s.taskpool.isNil:
    s.taskpool.shutdown()

  when defaultChroniclesStream.outputs.type.arity >= 3:
    proc noOutput(logLevel: LogLevel, msg: LogOutputStr) =
      discard

    defaultChroniclesStream.outputs[2].writer = noOutput

  if s.logFile.isSome:
    if error =? closeFile(s.logFile.get()).errorOption:
      error "Failed to close log file", errorCode = $error

  if res.failed.len > 0:
    error "Failed to close Storage node", failures = res.failed.len
    raise newException(
      StorageError,
      "Failed to close Storage node: " & res.failed.mapIt(it.error.msg).join(", "),
    )
  if res.cancelled.len > 0:
    warn "Storage node close was cancelled due to child close routine(s) being cancelled, child routines cancelled: ",
      cancellations = res.cancelled.len
    raise newException(
      CancelledError,
      "Storage node close was cancelled due to child close routine(s) being cancelled, child routines cancelled: " &
        $res.cancelled.len,
    )

proc shutdown*(server: StorageServer) {.async.} =
  await server.stop()
  await server.close()

proc new*(
    T: type StorageServer,
    config: StorageConf,
    privateKey: StoragePrivateKey,
    logFile: Option[IoHandle] = IoHandle.none,
): StorageServer =
  ## create StorageServer including setting up datastore, repostore, etc
  let listenMultiAddr = getMultiAddrWithIpAndTcpPort(config.listenIp, config.listenPort)

  let switch = SwitchBuilder
    .new()
    .withPrivateKey(privateKey)
    .withAddresses(@[listenMultiAddr], enableWildcardResolver = true)
    .withIdentifyPusher(false)
    .withRng(random.Rng.instance().libp2pRng)
    .withNoise()
    .withYamux()
    .withMaxConnections(config.maxPeers)
    .withAgentVersion(config.agentString)
    .withSignedPeerRecord(true)
    .withTcpTransport({ServerFlags.ReuseAddr, ServerFlags.TcpNoDelay})
    .build()

  var taskPool: Taskpool

  try:
    if config.numThreads == ThreadCount(0):
      taskPool = Taskpool.new(numThreads = min(countProcessors(), 16))
    else:
      taskPool = Taskpool.new(numThreads = int(config.numThreads))
    info "Threadpool started", numThreads = taskPool.numThreads
  except CatchableError as exc:
    raiseAssert("Failure in taskPool initialization:" & exc.msg)

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

  let bootstrapNodes =
    if config.noBootstrapNode:
      # Sanity checks that the user isn't doing anything funny.
      if config.bootstrapNodes.len > 0:
        error "Cannot specify bootstrap nodes when using no-bootstrap flag"
        raise newException(
          ValueError, "Cannot specify bootstrap nodes when using no-bootstrap flag"
        )

      warn "Node has been marked with --no-bootstrap-node and will NOT be bootstrapped"
      seq[SignedPeerRecord](@[])
    elif config.bootstrapNodes.len > 0:
      warn "Overriding network preset using custom bootstrap nodes",
        nodes = config.bootstrapNodes
      config.bootstrapNodes
    else:
      info "Bootstrapping node using a predefined network", network = $config.network
      config.network.bootstrapNodes

  let
    discoveryStore =
      Datastore(discoveryStoreRes.expect("Should create discovery datastore!"))

    discovery = Discovery.new(
      switch.peerInfo.privateKey,
      announceAddrs = @[listenMultiAddr],
      bindPort = config.discoveryPort,
      bootstrapNodes = bootstrapNodes,
      dhtMixProxies = config.dhtMixProxies,
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

    peerStore = PeerContextStore.new()
    downloadManager = DownloadManager.new(retries = config.blockRetries)
    advertiser = Advertiser.new(repoStore, discovery)
    blockDiscovery = DiscoveryEngine.new(repoStore, peerStore, network, discovery)
    engine = BlockExcEngine.new(
      repoStore, network, blockDiscovery, advertiser, peerStore, downloadManager
    )
    store = NetworkStore.new(engine, repoStore)
    manifestProto = ManifestProtocol.new(switch, repoStore, discovery)

    storageNode = StorageNodeRef.new(
      switch = switch,
      networkStore = store,
      engine = engine,
      discovery = discovery,
      manifestProto = manifestProto,
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
  switch.mount(manifestProto)

  # Enables private queries by default when mix is enabled.
  if config.mixEnabled:
    info "Enabling private queries over DHT by default", enabled = config.mixEnabled
    discard discovery.togglePrivateQueries(true)

  StorageServer(
    config: config,
    storageNode: storageNode,
    restServer: restServer,
    repoStore: repoStore,
    maintenance: maintenance,
    taskPool: taskPool,
    logFile: logFile,
  )
