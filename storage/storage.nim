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
import pkg/libp2p/protocols/connectivity/autonatv2/[service, client]
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
import ./utils/fileutils
import ./discovery
import ./utils/addrutils
import ./utils/natutils
import ./namespaces
import ./storagetypes
import ./logutils
import ./nat
import ./utils/natutils

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
    autonatService*: AutonatV2Service
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

  let announceIp =
    if s.config.nat.hasExtIp:
      some(s.config.nat.extIp)
    else:
      getBestLocalAddress(s.config.listenIp)

  if announceIp.isNone:
    # We should have an IP, even at private IP
    raise newException(StorageError, "Unable to determine an IP address to announce")

  # Remap switch addresses to the resolved IP (replaces 0.0.0.0 or :: with the actual address),
  # keeping unique entries only.
  let announceAddrs = s.storageNode.switch.peerInfo.addrs
    .mapIt(it.remapAddr(ip = announceIp, port = none(Port)))
    .deduplicate()
  let discoveryAddrs =
    @[getMultiAddrWithIPAndUDPPort(announceIp.get, s.config.discoveryPort)]
  s.storageNode.discovery.updateDhtRecord(announceAddrs & discoveryAddrs)
  s.storageNode.discovery.updateAnnounceRecord(announceAddrs)

  var hasPublicAddr = false
  for announceAddr in announceAddrs:
    let (maybeIp, _) = getAddressAndPort(announceAddr)
    if maybeIp.isSome and maybeIp.get.isGlobalUnicast():
      hasPublicAddr = true
      break

  if not hasPublicAddr:
    warn "Unable to determine a public IP address. This node will only be reachable on a private network."

  await s.storageNode.start()

  for spr in findReachableNodes(s.config.bootstrapNodes):
    try:
      let addrs = spr.data.addresses.mapIt(it.address)
      await s.storageNode.switch.connect(spr.data.peerId, addrs)
    except CatchableError as e:
      warn "Cannot connect to bootstrap node", error = e.msg
      discard

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
    raise newException(
      StorageError,
      "Failed to stop Storage node: " & res.failure.mapIt(it.error.msg).join(", "),
    )

proc close*(s: StorageServer) {.async.} =
  var futures =
    @[s.storageNode.close(), s.repoStore.close(), s.storageNode.discovery.close()]

  let res = await noCancel allFinishedFailed[void](futures)

  if not s.taskpool.isNil:
    try:
      s.taskpool.shutdown()
    except Exception as exc:
      error "Failed to stop the taskpool", failures = res.failure.len
      raise newException(StorageError, "Failure in taskpool shutdown: " & exc.msg)

  when defaultChroniclesStream.outputs.type.arity >= 3:
    proc noOutput(logLevel: LogLevel, msg: LogOutputStr) =
      discard

    defaultChroniclesStream.outputs[2].writer = noOutput

  if s.logFile.isSome:
    if error =? closeFile(s.logFile.get()).errorOption:
      error "Failed to close log file", errorCode = $error

  if res.failure.len > 0:
    error "Failed to close Storage node", failures = res.failure.len
    raise newException(
      StorageError,
      "Failed to close Storage node: " & res.failure.mapIt(it.error.msg).join(", "),
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

  let autonatClient = AutonatV2Client.new(random.Rng.instance())
  let autonatService = AutonatV2Service.new(
    rng = random.Rng.instance(),
    client = autonatClient,
    config = AutonatV2ServiceConfig.new(
      scheduleInterval = Opt.some(config.natScheduleInterval),
      askNewConnectedPeers = true,
      numPeersToAsk = config.natNumPeersToAsk,
      maxQueueSize = config.natMaxQueueSize,
      minConfidence = config.natMinConfidence,
    ),
  )

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
    .withAutonatV2Server()
    .withServices(@[Service(autonatService)])
    .build()

  var taskPool: Taskpool
  autonatClient.setup(switch)
  switch.mount(autonatClient)

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
        storageNode.initRestApi(
          config, repoStore, autonatService, config.apiCorsAllowedOrigin
        ),
        initTAddress(config.apiBindAddress.get(), config.apiPort),
        bufferSize = (1024 * 64),
        maxRequestBodySize = int.high,
      )
      .expect("Should create rest server!")

  switch.mount(network)
  switch.mount(manifestProto)

  let natMapper = DefaultNatMapper(natConfig: config.nat)
  autonatService.setStatusAndConfidenceHandler(
    proc(
        networkReachability: NetworkReachability, confidence: Opt[float]
    ) {.async: (raises: [CancelledError]).} =
      await handleNatStatus(
        networkReachability, confidence, natMapper, switch.peerInfo.addrs,
        config.discoveryPort, discovery,
      )
  )

  StorageServer(
    config: config,
    storageNode: storageNode,
    restServer: restServer,
    repoStore: repoStore,
    maintenance: maintenance,
    taskPool: taskPool,
    logFile: logFile,
    autonatService: autonatService,
  )
