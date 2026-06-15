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
import pkg/libp2p/connmanager
import pkg/libp2p/protocols/connectivity/autonatv2/[service, client]
import pkg/libp2p/protocols/connectivity/relay/client as relayClientModule
import pkg/libp2p/protocols/connectivity/relay/relay as relayModule
import pkg/libp2p/services/autorelayservice
import pkg/libp2p/transports/tcptransport
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
import ./namespaces
import ./storagetypes
import ./logutils
import ./nat
import ./utils/natutils

logScope:
  topics = "storage node"

const StorageTransportFlags = {ServerFlags.ReuseAddr, ServerFlags.TcpNoDelay}

proc tcpTransportBuilder(config: TransportConfig): Transport {.gcsafe, raises: [].} =
  TcpTransport.new(StorageTransportFlags, config.upgr)

type
  StorageServer* = ref object
    config: StorageConf
    logFile*: Option[IoHandle]
    restServer: RestServerRef
    storageNode: StorageNodeRef
    repoStore: RepoStore
    maintenance: BlockMaintainer
    taskpool: Taskpool
    # Expose to make reachability accessible from rest api
    autonatService*: Option[AutonatV2Service]
    autoRelayService*: Option[AutoRelayService]
    natMapper*: Option[NatPortMapper]
    holePunchHandler: Option[connmanager.PeerEventHandler]
    bootstrapNodes: seq[SignedPeerRecord]
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

  # When listenPort is 0 the OS assigns a random port. For UDP, the port
  # doesn't change so there is no need to update it.
  if s.natMapper.isSome and s.config.listenPort == Port(0):
    for listenAddr in s.storageNode.switch.peerInfo.listenAddrs:
      let maybePort = getTcpPort(listenAddr)
      if maybePort.isSome:
        s.natMapper.get.tcpPort = maybePort.get
        break

  # The addresses are announced during the start process
  # only with extIp because they should be Reachable.
  # For other nodes, wait for AutoNat to announce addresses and update SPR.
  if s.config.nat.hasExtIp:
    if s.storageNode.switch.peerInfo.addrs.len == 0:
      raise
        newException(StorageError, "extip is set but switch has no listen addresses")

    # extip means that we assume the IP is reachable.
    # So we just take the first peer addr and remap it with extip to keep the port only.
    let announceAddresses = @[
      s.storageNode.switch.peerInfo.addrs[0].remapAddr(
        ip = some(s.config.nat.extIp), port = none(Port)
      )
    ]
    s.storageNode.discovery.announceDirectAddrs(
      announceAddresses, udpPort = s.config.discoveryPort
    )
  else:
    # Other nodes wait for AutoNAT to announce addresses and update SPR.
    # They start in client mode to avoid polluting DHT with NotReachable records;
    # it will be flipped off once AutoNAT confirms reachability.
    s.storageNode.discovery.protocol.clientMode = true

  await s.storageNode.start()

  # Connect to the bootstrap nodes in order to have connected peers
  # for Autonat. The dials are run concurrently in case of
  # a dead bootstrap node that could timeout.
  proc connectBootstrapNode(
      spr: SignedPeerRecord
  ) {.async: (raises: [CancelledError]).} =
    try:
      let addrs = spr.data.addresses.mapIt(it.address)
      await s.storageNode.switch.connect(spr.data.peerId, addrs)
    except CancelledError as exc:
      raise exc
    except CatchableError as e:
      warn "Cannot connect to bootstrap node", error = e.msg

  await allFutures(findReachableNodes(s.bootstrapNodes).mapIt(connectBootstrapNode(it)))

  # AutoNAT is not in switch.services: start it after the bootstrap dials
  # so its first probe has peers to ask.
  if s.autonatService.isSome:
    await s.autonatService.get.start(s.storageNode.switch)

  if s.restServer != nil:
    s.restServer.start()

  s.isStarted = true

proc stop*(s: StorageServer) {.async.} =
  if not s.isStarted:
    warn "Storage is not started"
    return

  notice "Stopping Storage node"

  if s.natMapper.isSome:
    s.natMapper.get.stop()

  if s.holePunchHandler.isSome:
    s.storageNode.switch.removePeerEventHandler(
      s.holePunchHandler.get, PeerEventKind.Joined
    )

  var futures = @[
    s.storageNode.switch.stop(),
    s.storageNode.stop(),
    s.repoStore.stop(),
    s.maintenance.stop(),
  ]

  if s.autoRelayService.isSome and s.autoRelayService.get.isRunning:
    proc stopAutoRelay(): Future[void] {.async: (raises: []).} =
      await noCancel s.autoRelayService.get.stop(s.storageNode.switch)

    futures.add(stopAutoRelay())

  if s.autonatService.isSome:
    futures.add(s.autonatService.get.stop(s.storageNode.switch))

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
    transportBuilder: TransportBuilder = tcpTransportBuilder,
): StorageServer =
  ## create StorageServer including setting up datastore, repostore, etc.
  ## ``transportBuilder`` defaults to TCP; tests inject a simulated NAT transport.

  if err =? config.validateAutonatConfig().errorOption:
    raise newException(StorageError, err.msg)

  # Switch
  let listenMultiAddr = getMultiAddrWithIpAndTcpPort(config.listenIp, config.listenPort)

  let relayClient = RelayClient.new()
  let relay: Relay =
    if config.isRelayServer:
      Relay.new()
    else:
      relayClient

  var switchBuilder = SwitchBuilder
    .new()
    .withPrivateKey(privateKey)
    .withAddresses(@[listenMultiAddr])
    .withWildcardResolver()
    .withIdentifyPusher(false)
    .withRng(random.Rng.instance().libp2pRng)
    .withNoise()
    .withYamux()
    .withMaxConnections(config.maxPeers)
    .withAgentVersion(config.agentString)
    .withSignedPeerRecord(true)
    .withCircuitRelay(relay)

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

  var autonatConfig = none(AutonatV2ServiceConfig)
  if config.autonatServer:
    info "AutoNAT server enabled"
    switchBuilder = switchBuilder.withAutonatV2Server()
  elif not config.nat.hasExtIp:
    info "AutoNAT client enabled",
      scheduleInterval = config.natScheduleInterval,
      numPeersToAsk = config.natNumPeersToAsk,
      maxQueueSize = config.natMaxQueueSize,
      minConfidence = config.natMinConfidence
    autonatConfig = some(
      AutonatV2ServiceConfig.new(
        scheduleInterval = Opt.some(config.natScheduleInterval),
        askNewConnectedPeers = false,
        numPeersToAsk = config.natNumPeersToAsk,
        maxQueueSize = config.natMaxQueueSize,
        minConfidence = config.natMinConfidence,
        enableDialableCandidates = true,
      )
    )
    # At the first AutoNAT probe, the only identify observations available come
    # from the bootstrap nodes, so requiring more observations than there are
    # bootstrap nodes would make the threshold unreachable. The floor of 1
    # covers the case where the bootstrap list is empty.
    let observedAddrMinCount =
      max(1, min(config.natObservedAddrMinCount, bootstrapNodes.len))
    switchBuilder = switchBuilder.withObservedAddrManager(
      ObservedAddrManager.new(minCount = observedAddrMinCount)
    )
    # libp2p keeps the private address in peerInfo.addrs.
    # Since Autonat V2 uses the observed public address,
    # we can filter the private addresses to keep only the dialable
    # addresses.
    switchBuilder = switchBuilder.withAddressPolicy(dialableAddressPolicy)

  let switch = switchBuilder.withTransport(transportBuilder).build()

  var taskPool: Taskpool

  # AutoNAT's first reachability probe fires immediately on start.
  # Wired via withAutonatV2 it lands in switch.services and runs at switch.start,
  # before bootstrap, on an empty peer set.
  # We build and own it here so we can start it ourselves after bootstrap,
  # with the bootstrap peers connected.
  let autonatService: Option[AutonatV2Service] =
    if autonatConfig.isSome:
      let client = AutonatV2Client.new(switch.rng)
      client.setup(switch)
      switch.mount(client)
      let service = AutonatV2Service.new(switch.rng, client, autonatConfig.get)
      service.setup(switch)
      some(service)
    else:
      none(AutonatV2Service)

  # Storage infrastructure

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

  let
    discoveryStore =
      Datastore(discoveryStoreRes.expect("Should create discovery datastore!"))

    discovery = Discovery.new(
      switch.peerInfo.privateKey,
      announceAddrs = @[],
      bindPort = config.discoveryPort,
      bootstrapNodes = bootstrapNodes,
      discoveryPort = config.discoveryPort,
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

  switch.mount(network)
  switch.mount(manifestProto)

  # NAT services
  var natMapper: Option[NatPortMapper]
  var autoRelayService: Option[AutoRelayService]
  var holePunchHandler: Option[connmanager.PeerEventHandler]

  if autonatService.isSome:
    let relayService = AutoRelayService.new(
      maxNumRelays = config.natMaxRelays,
      client = relayClient,
      onReservation = proc(addresses: seq[MultiAddress]) {.gcsafe, raises: [].} =
        # A relay server is required to have a public extip, so its
        # circuit addresses always include a public one. The relay's reservation
        # response can also carry loopback/private addresses:
        # they are never dialable by a remote peer, so drop them.
        let publicAddrs = addresses.filterIt(it.hasPublicRelayTransport())
        if publicAddrs.len == 0:
          warn "Relay reservation has no publicly dialable address, keeping previous announce",
            addresses
          return
        info "Relay reservation updated", addresses = publicAddrs
        # relay addresses are for download traffic only, not DHT routing
        discovery.announceRelayAddrs(publicAddrs),
      rng = random.Rng.instance().libp2pRng,
    )

    relayService.setup(switch)
    autoRelayService = some(relayService)

    natMapper = some(
      NatPortMapper(
        natConfig: config.nat,
        tcpPort: config.listenPort,
        discoveryPort: config.discoveryPort,
        discoverTimeout: config.natPortMappingDiscoverTimeout,
        mappingTimeout: config.natPortMappingTimeout,
        recheckPeriod: config.natPortMappingRecheckPeriod,
      )
    )

    setupMappedAddrMapper(switch, natMapper.get)

    autonatService.get.setStatusAndConfidenceHandler(
      proc(
          networkReachability: NetworkReachability,
          confidence: Opt[float],
          addrs: Opt[MultiAddress],
      ) {.async: (raises: [CancelledError]).} =
        debug "AutoNAT status", reachability = networkReachability, confidence
        await natMapper.get.handleNatStatus(
          networkReachability, addrs, config.discoveryPort, discovery, switch,
          relayService,
        )
    )

    holePunchHandler = some(setupHolePunching(switch))

  # REST server
  var restServer: RestServerRef = nil

  if config.apiBindAddress.isSome:
    restServer = RestServerRef
      .new(
        storageNode.initRestApi(
          config, repoStore, autonatService, autoRelayService, natMapper,
          config.apiCorsAllowedOrigin,
        ),
        initTAddress(config.apiBindAddress.get(), config.apiPort),
        bufferSize = (1024 * 64),
        maxRequestBodySize = int.high,
      )
      .expect("Should create rest server!")

  StorageServer(
    config: config,
    storageNode: storageNode,
    restServer: restServer,
    repoStore: repoStore,
    maintenance: maintenance,
    taskPool: taskPool,
    logFile: logFile,
    autonatService: autonatService,
    autoRelayService: autoRelayService,
    natMapper: natMapper,
    holePunchHandler: holePunchHandler,
    bootstrapNodes: bootstrapNodes,
  )
