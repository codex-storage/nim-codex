## Nim-Dagger
## Copyright (c) 2021 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import std/sequtils
import std/sets

import pkg/chronos
import pkg/chronicles
import pkg/libp2p

import ../stores/blockstore
import ../blocktype as bt
import ../utils
import ../discovery

import ./protobuf/blockexc
import ./protobuf/presence

import ./network
import ./pendingblocks
import ./peercontext
import ./engine/payments

export peercontext, payments, pendingblocks

logScope:
  topics = "dagger blockexc engine"

const
  DefaultMaxPeersPerRequest* = 10
  DefaultTaskQueueSize = 100
  DefaultConcurrentTasks = 10
  DefaultMaxRetries = 3
  DefaultConcurrentDiscRequests = 10
  DefaultConcurrentAdvertRequests = 10
  DefaultDiscoveryTimeout = 1.minutes
  DefaultMaxQueriedBlocksCache = 1000
  DefaultMinPeersPerBlock = 3

type
  TaskHandler* = proc(task: BlockExcPeerCtx): Future[void] {.gcsafe.}
  TaskScheduler* = proc(task: BlockExcPeerCtx): bool {.gcsafe.}

  BlockExcEngine* = ref object of RootObj
    localStore*: BlockStore                       # where we localStore blocks for this instance
    network*: BlockExcNetwork                     # network interface
    peers*: seq[BlockExcPeerCtx]                  # peers we're currently actively exchanging with
    taskQueue*: AsyncHeapQueue[BlockExcPeerCtx]   # peers we're currently processing tasks for
    concurrentTasks: int                          # number of concurrent peers we're serving at any given time
    maxRetries: int                               # max number of tries for a failed block
    blockexcTasks: seq[Future[void]]              # future to control blockexc task
    blockexcRunning: bool                         # indicates if the blockexc task is running
    pendingBlocks*: PendingBlocksManager          # blocks we're awaiting to be resolved
    peersPerRequest: int                          # max number of peers to request from
    wallet*: WalletRef                            # nitro wallet for micropayments
    pricing*: ?Pricing                            # optional bandwidth pricing
    discovery*: Discovery                         # Discovery interface
    concurrentAdvReqs: int                        # Concurrent advertise requests
    advertiseLoop*: Future[void]                  # Advertise loop task handle
    advertiseQueue*: AsyncQueue[Cid]              # Advertise queue
    advertiseTasks*: seq[Future[void]]            # Advertise tasks
    concurrentDiscReqs: int                       # Concurrent discovery requests
    discoveryLoop*: Future[void]                  # Discovery loop task handle
    discoveryTasks*: seq[Future[void]]            # Discovery tasks
    discoveryQueue*: AsyncQueue[Cid]              # Discovery queue
    minPeersPerBlock*: int                        # Max number of peers with block

  Pricing* = object
    address*: EthAddress
    price*: UInt256

proc contains*(a: AsyncHeapQueue[Entry], b: Cid): bool =
  ## Convenience method to check for entry prepense
  ##

  a.anyIt( it.cid == b )

proc getPeerCtx*(b: BlockExcEngine, peerId: PeerID): BlockExcPeerCtx =
  ## Get the peer's context
  ##

  let peer = b.peers.filterIt( it.id == peerId )
  if peer.len > 0:
    return peer[0]

# attach task scheduler to engine
proc scheduleTask(b: BlockExcEngine, task: BlockExcPeerCtx): bool {.gcsafe} =
  b.taskQueue.pushOrUpdateNoWait(task).isOk()

proc blockexcTaskRunner(b: BlockExcEngine): Future[void] {.gcsafe.}

proc discoveryLoopRunner(b: BlockExcEngine) {.async.} =
  while b.blockexcRunning:
    for cid in toSeq(b.pendingBlocks.wantList):
      try:
        await b.discoveryQueue.put(cid)
      except CatchableError as exc:
        trace "Exception in discovery loop", exc = exc.msg

    trace "About to sleep, number of wanted blocks", wanted = b.pendingBlocks.len
    await sleepAsync(30.seconds)

proc advertiseLoopRunner*(b: BlockExcEngine) {.async.} =
  proc onBlock(cid: Cid) {.async.} =
    try:
      await b.advertiseQueue.put(cid)
    except CatchableError as exc:
      trace "Exception listing blocks", exc = exc.msg

  while b.blockexcRunning:
    await b.localStore.listBlocks(onBlock)
    await sleepAsync(30.seconds)

  trace "Exiting advertise task loop"

proc advertiseTaskRunner(b: BlockExcEngine) {.async.} =
  ## Run advertise tasks
  ##

  while b.blockexcRunning:
    try:
      let cid = await b.advertiseQueue.get()
      await b.discovery.provideBlock(cid)
    except CatchableError as exc:
      trace "Exception in advertise task runner", exc = exc.msg

  trace "Exiting advertise task runner"

proc discoveryTaskRunner(b: BlockExcEngine) {.async.} =
  ## Run discovery tasks
  ##

  while b.blockexcRunning:
    try:
      let
        cid = await b.discoveryQueue.get()
        haves = b.peers.filterIt(
          it.peerHave.anyIt( it == cid )
        )

      trace "Got peers for block", cid = $cid, count = haves.len
      let
        providers =
          if haves.len < b.minPeersPerBlock:
            await b.discovery
              .findBlockProviders(cid)
              .wait(DefaultDiscoveryTimeout)
          else:
            @[]

      checkFutures providers.mapIt( b.network.dialPeer(it.data) )
    except CatchableError as exc:
      trace "Exception in discovery task runner", exc = exc.msg

  trace "Exiting discovery task runner"

proc queueFindBlocksReq(b: BlockExcEngine, cids: seq[Cid]) {.async.} =
  try:
    for cid in cids:
      if cid notin b.discoveryQueue:
        await b.discoveryQueue.put(cid)
  except CatchableError as exc:
    trace "Exception queueing discovery request", exc = exc.msg

proc queueProvideBlocksReq(b: BlockExcEngine, cids: seq[Cid]) {.async.} =
  try:
    for cid in cids:
      if cid notin b.advertiseQueue:
        await b.advertiseQueue.put(cid)
  except CatchableError as exc:
    trace "Exception queueing discovery request", exc = exc.msg

proc start*(b: BlockExcEngine) {.async.} =
  ## Start the blockexc task
  ##

  trace "blockexc start"

  if b.blockexcRunning:
    warn "Starting blockexc twice"
    return

  b.blockexcRunning = true
  for i in 0..<b.concurrentTasks:
    b.blockexcTasks.add(blockexcTaskRunner(b))

  for i in 0..<b.concurrentAdvReqs:
    b.advertiseTasks.add(advertiseTaskRunner(b))

  for i in 0..<b.concurrentDiscReqs:
    b.discoveryTasks.add(discoveryTaskRunner(b))

  b.advertiseLoop = advertiseLoopRunner(b)
  b.discoveryLoop = discoveryLoopRunner(b)

proc stop*(b: BlockExcEngine) {.async.} =
  ## Stop the blockexc blockexc
  ##

  trace "NetworkStore stop"
  if not b.blockexcRunning:
    warn "Stopping blockexc without starting it"
    return

  b.blockexcRunning = false
  for t in b.blockexcTasks:
    if not t.finished:
      trace "Awaiting task to stop"
      await t.cancelAndWait()
      trace "Task stopped"

  for t in b.advertiseTasks:
    if not t.finished:
      trace "Awaiting task to stop"
      await t.cancelAndWait()
      trace "Task stopped"

  for t in b.discoveryTasks:
    if not t.finished:
      trace "Awaiting task to stop"
      await t.cancelAndWait()
      trace "Task stopped"

  if not b.advertiseLoop.isNil and not b.advertiseLoop.finished:
    trace "Awaiting advertise loop to stop"
    await b.advertiseLoop.cancelAndWait()
    trace "Advertise loop stopped"

  if not b.discoveryLoop.isNil and not b.discoveryLoop.finished:
    trace "Awaiting discovery loop to stop"
    await b.discoveryLoop.cancelAndWait()
    trace "Discovery loop stopped"

  trace "NetworkStore stopped"

proc requestBlock*(
  b: BlockExcEngine,
  cid: Cid,
  timeout = DefaultBlockTimeout): Future[bt.Block] =
  ## Request a block from remotes
  ##

  if cid in b.pendingBlocks:
    return b.pendingBlocks.getWantHandle(cid, timeout)

  let
    blk = b.pendingBlocks.getWantHandle(cid, timeout)

  if b.peers.len <= 0:
    trace "No peers to request blocks from", cid = $cid
    asyncSpawn b.queueFindBlocksReq(@[cid])
    return blk

  var peers = b.peers

  # get the first peer with at least one (any)
  # matching cid
  # TODO: this should be sorted by best to worst
  var blockPeer: BlockExcPeerCtx
  for p in peers:
    if cid in p.peerHave:
      blockPeer = p
      break

  # didn't find any peer with matching cids
  if isNil(blockPeer):
    blockPeer = peers[0]

  peers.keepItIf(
    it != blockPeer and cid notin it.peerHave
  )

  # request block
  b.network.request.sendWantList(
    blockPeer.id,
    @[cid],
    wantType = WantType.wantBlock) # we want this remote to send us a block

  if peers.len == 0:
    trace "Not enough peers to send want list to", cid = $cid
    asyncSpawn b.queueFindBlocksReq(@[cid])
    return blk # no peers to send wants to

  # filter out the peer we've already requested from
  let stop = min(peers.high, b.peersPerRequest)
  trace "Sending want list requests to remaining peers", count = stop + 1
  for p in peers[0..stop]:
    if cid notin p.peerHave:
      # just send wants
      b.network.request.sendWantList(
        p.id,
        @[cid],
        wantType = WantType.wantHave) # we only want to know if the peer has the block

  return blk

proc blockPresenceHandler*(
  b: BlockExcEngine,
  peer: PeerID,
  blocks: seq[BlockPresence]) {.async.} =
  ## Handle block presence
  ##

  trace "Received presence update for peer", peer
  let peerCtx = b.getPeerCtx(peer)
  if isNil(peerCtx):
    return

  for blk in blocks:
    if presence =? Presence.init(blk):
      peerCtx.updatePresence(presence)

  var
    cids = toSeq(b.pendingBlocks.wantList).filterIt(
      it in peerCtx.peerHave
    )

  if cids.len > 0:
    b.network.request.sendWantList(
      peer,
      cids,
      wantType = WantType.wantBlock) # we want this remote to send us a block

  # if none of the connected peers report our wants in their have list,
  # fire up discovery
  asyncSpawn b.queueFindBlocksReq(
    toSeq(b.pendingBlocks.wantList).filter(proc(cid: Cid): bool =
      (not b.peers.anyIt( cid in it.peerHave ))))

proc scheduleTasks(b: BlockExcEngine, blocks: seq[bt.Block]) =
  trace "Schedule a task for new blocks"

  let cids = blocks.mapIt( it.cid )
  # schedule any new peers to provide blocks to
  for p in b.peers:
    for c in cids: # for each cid
        # schedule a peer if it wants at least one
        # cid and we have it in our local store
        if c in p.peerWants and c in b.localStore:
          if not b.scheduleTask(p):
            trace "Unable to schedule task for peer", peer = p.id
          break # do next peer

proc resolveBlocks*(b: BlockExcEngine, blocks: seq[bt.Block]) =
  ## Resolve pending blocks from the pending blocks manager
  ## and schedule any new task to be ran
  ##

  trace "Resolving blocks", blocks = blocks.len

  b.pendingBlocks.resolve(blocks)
  b.scheduleTasks(blocks)
  asyncSpawn b.queueProvideBlocksReq(blocks.mapIt( it.cid ))

proc payForBlocks(engine: BlockExcEngine,
                  peer: BlockExcPeerCtx,
                  blocks: seq[bt.Block]) =
  let sendPayment = engine.network.request.sendPayment
  if sendPayment.isNil:
    return

  let cids = blocks.mapIt(it.cid)
  if payment =? engine.wallet.pay(peer, peer.price(cids)):
    sendPayment(peer.id, payment)

proc blocksHandler*(
  b: BlockExcEngine,
  peer: PeerID,
  blocks: seq[bt.Block]) {.async.} =
  ## handle incoming blocks
  ##

  trace "Got blocks from peer", peer, len = blocks.len
  for blk in blocks:
    if not (await b.localStore.putBlock(blk)):
      trace "Unable to store block", cid = blk.cid
      continue

  b.resolveBlocks(blocks)
  let peerCtx = b.getPeerCtx(peer)
  if peerCtx != nil:
    b.payForBlocks(peerCtx, blocks)

proc wantListHandler*(
  b: BlockExcEngine,
  peer: PeerID,
  wantList: WantList) {.async.} =
  ## Handle incoming want lists
  ##

  trace "Got want list for peer", peer
  let peerCtx = b.getPeerCtx(peer)
  if isNil(peerCtx):
    return

  var dontHaves: seq[Cid]
  let entries = wantList.entries
  for e in entries:
    let idx = peerCtx.peerWants.find(e)
    if idx > -1:
      # peer doesn't want this block anymore
      if e.cancel:
        peerCtx.peerWants.del(idx)
        continue

      peerCtx.peerWants[idx] = e # update entry
    else:
      peerCtx.peerWants.add(e)

    trace "Added entry to peer's want list", peer = peerCtx.id, cid = $e.cid

    # peer might want to ask for the same cid with
    # different want params
    if e.sendDontHave and e.cid notin b.localStore:
      dontHaves.add(e.cid)

  # send don't have's to remote
  if dontHaves.len > 0:
    b.network.request.sendPresence(
      peer,
      dontHaves.mapIt(
        BlockPresence(
          cid: it.data.buffer,
          `type`: BlockPresenceType.presenceDontHave)))

  if not b.scheduleTask(peerCtx):
    trace "Unable to schedule task for peer", peer

proc accountHandler*(
  engine: BlockExcEngine,
  peer: PeerID,
  account: Account) {.async.} =
  let context = engine.getPeerCtx(peer)
  if context.isNil:
    return

  context.account = account.some

proc paymentHandler*(
  engine: BlockExcEngine,
  peer: PeerId,
  payment: SignedState) {.async.} =
  without context =? engine.getPeerCtx(peer).option and
          account =? context.account:
    return

  if channel =? context.paymentChannel:
    let sender = account.address
    discard engine.wallet.acceptPayment(channel, Asset, sender, payment)
  else:
    context.paymentChannel = engine.wallet.acceptChannel(payment).option

proc setupPeer*(b: BlockExcEngine, peer: PeerID) =
  ## Perform initial setup, such as want
  ## list exchange
  ##

  trace "Setting up new peer", peer
  if peer notin b.peers:
    b.peers.add(BlockExcPeerCtx(
      id: peer
    ))

  # broadcast our want list, the other peer will do the same
  if b.pendingBlocks.len > 0:
    b.network.request.sendWantList(peer, toSeq(b.pendingBlocks.wantList), full = true)

  if address =? b.pricing.?address:
    b.network.request.sendAccount(peer, Account(address: address))

proc dropPeer*(b: BlockExcEngine, peer: PeerID) =
  ## Cleanup disconnected peer
  ##

  trace "Dropping peer", peer

  # drop the peer from the peers table
  b.peers.keepItIf( it.id != peer )

proc taskHandler*(b: BlockExcEngine, task: BlockExcPeerCtx) {.gcsafe, async.} =
  trace "Handling task for peer", peer = task.id

  var wantsBlocks = newAsyncHeapQueue[Entry](queueType = QueueType.Max)
  # get blocks and wants to send to the remote
  for e in task.peerWants:
    if e.wantType == WantType.wantBlock:
      await wantsBlocks.push(e)

  # TODO: There should be all sorts of accounting of
  # bytes sent/received here
  if wantsBlocks.len > 0:
    let blockFuts = await allFinished(wantsBlocks.mapIt(
        b.localStore.getBlock(it.cid)
    ))

    let blocks = blockFuts
      .filterIt((not it.failed) and it.read.isOk)
      .mapIt(!it.read)

    if blocks.len > 0:
      trace "Sending blocks to peer", peer = task.id, blocks = blocks.len
      b.network.request.sendBlocks(
        task.id,
        blocks)

    # Remove successfully sent blocks
    task.peerWants.keepIf(
      proc(e: Entry): bool =
        not blocks.anyIt( it.cid == e.cid )
    )

  var wants: seq[BlockPresence]
  # do not remove wants from the queue unless
  # we send the block or get a cancel
  for e in task.peerWants:
    if e.wantType == WantType.wantHave:
      var presence = Presence(cid: e.cid)
      presence.have = b.localStore.hasblock(presence.cid)
      if presence.have and price =? b.pricing.?price:
        presence.price = price
      wants.add(BlockPresence.init(presence))

  if wants.len > 0:
    b.network.request.sendPresence(task.id, wants)

proc blockexcTaskRunner(b: BlockExcEngine) {.async.} =
  ## process tasks
  ##

  while b.blockexcRunning:
    let peerCtx = await b.taskQueue.pop()
    asyncSpawn b.taskHandler(peerCtx)

  trace "Exiting blockexc task runner"

proc new*(
  T: type BlockExcEngine,
  localStore: BlockStore,
  wallet: WalletRef,
  network: BlockExcNetwork,
  discovery: Discovery,
  concurrentTasks = DefaultConcurrentTasks,
  maxRetries = DefaultMaxRetries,
  peersPerRequest = DefaultMaxPeersPerRequest,
  concurrentAdvReqs = DefaultConcurrentAdvertRequests,
  concurrentDiscReqs = DefaultConcurrentDiscRequests): T =

  let
    engine = BlockExcEngine(
      localStore: localStore,
      pendingBlocks: PendingBlocksManager.new(),
      peersPerRequest: peersPerRequest,
      network: network,
      wallet: wallet,
      concurrentTasks: concurrentTasks,
      concurrentAdvReqs: concurrentAdvReqs,
      concurrentDiscReqs: concurrentDiscReqs,
      maxRetries: maxRetries,
      taskQueue: newAsyncHeapQueue[BlockExcPeerCtx](DefaultTaskQueueSize),
      discovery: discovery,
      advertiseQueue: newAsyncQueue[Cid](DefaultTaskQueueSize),
      minPeersPerBlock: minPeersPerBlock)

  proc peerEventHandler(peerId: PeerID, event: PeerEvent) {.async.} =
    if event.kind == PeerEventKind.Joined:
      engine.setupPeer(peerId)
    else:
      engine.dropPeer(peerId)

  if not isNil(network.switch):
    network.switch.addPeerEventHandler(peerEventHandler, PeerEventKind.Joined)
    network.switch.addPeerEventHandler(peerEventHandler, PeerEventKind.Left)

  proc blockWantListHandler(
    peer: PeerID,
    wantList: WantList): Future[void] {.gcsafe.} =
    engine.wantListHandler(peer, wantList)

  proc blockPresenceHandler(
    peer: PeerID,
    presence: seq[BlockPresence]): Future[void] {.gcsafe.} =
    engine.blockPresenceHandler(peer, presence)

  proc blocksHandler(
    peer: PeerID,
    blocks: seq[bt.Block]): Future[void] {.gcsafe.} =
    engine.blocksHandler(peer, blocks)

  proc accountHandler(peer: PeerId, account: Account): Future[void] {.gcsafe.} =
    engine.accountHandler(peer, account)

  proc paymentHandler(peer: PeerId, payment: SignedState): Future[void] {.gcsafe.} =
    engine.paymentHandler(peer, payment)

  network.handlers = BlockExcHandlers(
    onWantList: blockWantListHandler,
    onBlocks: blocksHandler,
    onPresence: blockPresenceHandler,
    onAccount: accountHandler,
    onPayment: paymentHandler)

  return engine
