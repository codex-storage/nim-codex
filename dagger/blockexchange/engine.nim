## Nim-Dagger
## Copyright (c) 2021 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import std/[sequtils, sets, tables, sugar]

import pkg/chronos
import pkg/chronicles
import pkg/libp2p

import ../stores/blockstore
import ../blocktype as bt
import ../utils/asyncheapqueue
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
  DefaultBlockTimeout* = 5.minutes
  DefaultMaxPeersPerRequest* = 10
  DefaultTaskQueueSize = 100
  DefaultConcurrentTasks = 10
  DefaultMaxRetries = 3

  # Current advertisement is meant to be more efficient than
  # correct, so blocks could be advertised more slowly than that
  # Put some margin
  BlockAdvertisementFrequency = 30.minutes

type
  TaskHandler* = proc(task: BlockExcPeerCtx): Future[void] {.gcsafe.}
  TaskScheduler* = proc(task: BlockExcPeerCtx): bool {.gcsafe.}

  BlockDiscovery* = ref object
    discoveredProvider: AsyncEvent
    running: AsyncEvent
    discoveryLoop: Future[void]
    toDiscover: Cid
    inflightIWant: HashSet[PeerId]
    gotIWantResponse: AsyncEvent
    provides: seq[PeerId]

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
    advertisedBlocks: seq[Cid]
    advertisedIndex: int
    advertisementFrequency: Duration
    runningDiscoveries*: Table[Cid, BlockDiscovery]
    blockAdded: AsyncEvent
    discovery*: Discovery

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
proc advertiseLoop(b: BlockExcEngine): Future[void] {.gcsafe.}

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

  info "Getting existing block list"
  let blocks = await b.localStore.blockList()
  b.advertisedBlocks = blocks
  # We start faster to publish everything ASAP
  b.advertisementFrequency = 5.seconds

  b.blockexcTasks.add(b.advertiseLoop())

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

  for _, bd in b.runningDiscoveries:
    await bd.discoveryLoop.cancelAndWait()

  b.runningDiscoveries.clear()

  trace "NetworkStore stopped"

proc lowInflight(bd: BlockDiscovery) {.async.} =
  while bd.inflightIWant.len > 3:
    await bd.gotIWantResponse.wait()
    bd.gotIWantResponse.clear()

proc discoveredPeer(bd: BlockDiscovery, peer: PeerId, hasBlock: bool) =
  bd.inflightIWant.excl(peer)
  if hasBlock and peer notin bd.provides:
    bd.provides.add(peer)
    bd.discoveredProvider.fire()
    bd.running.clear()
  bd.gotIWantResponse.fire()

proc resume(bd: BlockDiscovery) = bd.running.fire()

proc discoverLoop(b: BlockExcEngine, bd: BlockDiscovery) {.async.} =
  debug "starting block discovery", cid=bd.toDiscover

  # Check current peers
  for p in b.peers:
    if bd.toDiscover in p.peerHave:
      bd.provides.add(p.id)
    else:
      b.network.request.sendWantList(
        p.id,
        @[bd.toDiscover],
        wantType = WantType.wantHave,
        sendDontHave = true)
      bd.inflightIWant.incl(p.id)

  if bd.provides.len > 0:
    bd.discoveredProvider.fire()
    bd.running.clear()

  await bd.lowInflight() or sleepAsync(500.milliseconds)

  while true:
    await bd.running.wait()
    debug "asking peers", cid=bd.toDiscover
    #start query
    let discoveredProviders = await b.discovery.findBlockProviders(bd.toDiscover)
    for peer in discoveredProviders:
      asyncSpawn b.network.dialPeer(peer.data)
    await sleepAsync(30.seconds)

proc discoverBlock*(b: BlockExcEngine, cid: Cid): BlockDiscovery =
  if cid in b.runningDiscoveries:
    return b.runningDiscoveries[cid]
  else:
    result = BlockDiscovery(
      toDiscover: cid,
      discoveredProvider: newAsyncEvent(),
      gotIWantResponse: newAsyncEvent(),
      running: newAsyncEvent(),
    )
    result.running.fire()
    result.discoveryLoop = b.discoverLoop(result)
    b.runningDiscoveries[cid] = result
    return result

proc stopDiscovery(b: BlockExcEngine, cid: Cid) =
  if cid in b.runningDiscoveries:
    b.runningDiscoveries[cid].discoveryLoop.cancel()
    b.runningDiscoveries.del(cid)

proc blockGetter(
  b: BlockExcEngine,
  cid: Cid) {.async.} =
  let
    timeoutFut = sleepAsync(DefaultBlockTimeout)
    blk = b.pendingBlocks.addOrAwait(cid)
    discovery = b.discoverBlock(cid)

  defer: b.stopDiscovery(cid)

  # TODO handle cancellation
  # need to count how much people are waiting for the pending
  # block, and stop this if it hit 0

  while not blk.finished:
    await timeoutFut or blk or discovery.discoveredProvider.wait()

    if timeoutFut.finished:
      # Timeout passed, fail the block
      blk.cancel()
      return

    if blk.finished:
      # a peer sent us the block out of the blue
      return

    # We got a provider
    # In reality, we could keep discovering until we find a suitable price, etc
    while discovery.provides.len > 0:
      let provider = discovery.provides.pop()

      debug "Requesting block from peer", providerCount = discovery.provides.len + 1,
        peer = provider, cid
      # request block
      b.network.request.sendWantList(
        provider,
        @[cid],
        wantType = WantType.wantBlock) # we want this remote to send us a block

      if await blk.withTimeout(1.seconds):
        # got the block
        return

    # No discovered peer sent us the block, restart discovery
    discovery.resume()

proc requestBlock*(
  b: BlockExcEngine,
  cid: Cid,
  timeout = DefaultBlockTimeout): Future[bt.Block] {.async.} =
  ## Request a block from remotes
  ##

  debug "requesting block", cid

  # TODO
  # we could optimize "groups of related chunks"
  # be requesting multiple chunks, and running discovery
  # less often

  if cid in b.localStore:
    return (await b.localStore.getBlock(cid)).get()

  # be careful, don't give back control to main loop here
  # otherwise, the block might slip in

  if cid notin b.pendingBlocks:
    # We are the first one to request this block, so we handle it
    asyncSpawn b.blockGetter(cid)

  return await b.pendingBlocks.addOrAwait(cid).wait(timeout)

proc blockPresenceHandler*(
  b: BlockExcEngine,
  peer: PeerID,
  blocks: seq[BlockPresence]) {.async.} =
  ## Handle block presence
  ##

  let peerCtx = b.getPeerCtx(peer)

  for blk in blocks:
    if presence =? Presence.init(blk):
      if not isNil(peerCtx):
        peerCtx.updatePresence(presence)
      if presence.cid in b.runningDiscoveries:
        let bd = b.runningDiscoveries[presence.cid]
        bd.discoveredPeer(peer, presence.have)

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

  trace "Resolving blocks"

  var gotNewBlocks = false
  for bl in blocks:
    if bl.cid notin b.advertisedBlocks: #TODO that's very slow, maybe a ordered hashset instead
      #TODO could do some smarter ordering here (insert it just before b.advertisedIndex, or similar)
      b.advertisedBlocks.add(bl.cid)
      asyncSpawn b.discovery.publishProvide(bl.cid)
      gotNewBlocks = true

  if gotNewBlocks:
    b.pendingBlocks.resolve(blocks)
    b.scheduleTasks(blocks)

    b.blockAdded.fire()

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

proc accountHandler*(engine: BlockExcEngine, peer: PeerID, account: Account) {.async.} =
  let context = engine.getPeerCtx(peer)
  if context.isNil:
    return

  context.account = account.some

proc paymentHandler*(engine: BlockExcEngine, peer: PeerId, payment: SignedState) {.async.} =
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
  let wantList = collect(newSeqOfCap(b.runningDiscoveries.len)):
    for cid, bd in b.runningDiscoveries:
      bd.inflightIWant.incl(peer)
      cid

  if wantList.len > 0:
    b.network.request.sendWantList(peer, wantList, full = true)

  if address =? b.pricing.?address:
    b.network.request.sendAccount(peer, Account(address: address))

proc dropPeer*(b: BlockExcEngine, peer: PeerID) =
  ## Cleanup disconnected peer
  ##

  trace "Dropping peer", peer

  # drop the peer from the peers table
  b.peers.keepItIf( it.id != peer )

proc advertiseLoop(b: BlockExcEngine) {.async, gcsafe.} =
  while true:
    if b.advertisedIndex >= b.advertisedBlocks.len:
      b.advertisedIndex = 0
      b.advertisementFrequency = BlockAdvertisementFrequency

    # check that we still have this block.
    while
      b.advertisedIndex < b.advertisedBlocks.len and
      not(b.localStore.contains(b.advertisedBlocks[b.advertisedIndex])):
        b.advertisedBlocks.delete(b.advertisedIndex)

    #publish it
    if b.advertisedIndex < b.advertisedBlocks.len:
      asyncSpawn b.discovery.publishProvide(b.advertisedBlocks[b.advertisedIndex])

    inc b.advertisedIndex
    let toSleep =
      if b.advertisedBlocks.len > 0:
        b.advertisementFrequency div b.advertisedBlocks.len
      else:
        30.minutes
    await sleepAsync(toSleep) or b.blockAdded.wait()
    b.blockAdded.clear()

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
  peersPerRequest = DefaultMaxPeersPerRequest): T =

  let engine = BlockExcEngine(
    localStore: localStore,
    pendingBlocks: PendingBlocksManager.new(),
    blockAdded: newAsyncEvent(),
    peersPerRequest: peersPerRequest,
    network: network,
    wallet: wallet,
    concurrentTasks: concurrentTasks,
    maxRetries: maxRetries,
    discovery: discovery,
    taskQueue: newAsyncHeapQueue[BlockExcPeerCtx](DefaultTaskQueueSize))

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
    onPayment: paymentHandler
  )

  return engine
