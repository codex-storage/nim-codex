## Nim-Codex
## Copyright (c) 2021 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import std/sequtils
import std/sets
import std/options
import std/algorithm

import pkg/chronos
import pkg/chronicles
import pkg/libp2p
import pkg/stint

import ../../stores/blockstore
import ../../blocktype as bt
import ../../utils

import ../protobuf/blockexc
import ../protobuf/presence

import ../network
import ../peers

import ./payments
import ./discovery
import ./pendingblocks

export peers, pendingblocks, payments, discovery

logScope:
  topics = "codex blockexcengine"

const
  DefaultMaxPeersPerRequest* = 10
  DefaultTaskQueueSize = 100
  DefaultConcurrentTasks = 10
  # DefaultMaxRetries = 3
  # DefaultConcurrentDiscRequests = 10
  # DefaultConcurrentAdvertRequests = 10
  # DefaultDiscoveryTimeout = 1.minutes
  # DefaultMaxQueriedBlocksCache = 1000
  # DefaultMinPeersPerBlock = 3

type
  TaskHandler* = proc(task: BlockExcPeerCtx): Future[void] {.gcsafe.}
  TaskScheduler* = proc(task: BlockExcPeerCtx): bool {.gcsafe.}

  BlockExcEngine* = ref object of RootObj
    localStore*: BlockStore                       # Local block store for this instance
    network*: BlockExcNetwork                     # Petwork interface
    peers*: PeerCtxStore                          # Peers we're currently actively exchanging with
    taskQueue*: AsyncHeapQueue[BlockExcPeerCtx]   # Peers we're currently processing tasks for
    concurrentTasks: int                          # Number of concurrent peers we're serving at any given time
    blockexcTasks: seq[Future[void]]              # Future to control blockexc task
    blockexcRunning: bool                         # Indicates if the blockexc task is running
    pendingBlocks*: PendingBlocksManager          # Blocks we're awaiting to be resolved
    peersPerRequest: int                          # Max number of peers to request from
    wallet*: WalletRef                            # Nitro wallet for micropayments
    pricing*: ?Pricing                            # Optional bandwidth pricing
    discovery*: DiscoveryEngine

  Pricing* = object
    address*: EthAddress
    price*: UInt256

proc contains*(a: AsyncHeapQueue[Entry], b: Cid): bool =
  ## Convenience method to check for entry prepense
  ##

  a.anyIt( it.cid == b )

# attach task scheduler to engine
proc scheduleTask(b: BlockExcEngine, task: BlockExcPeerCtx): bool {.gcsafe} =
  b.taskQueue.pushOrUpdateNoWait(task).isOk()

proc blockexcTaskRunner(b: BlockExcEngine): Future[void] {.gcsafe.}

proc start*(b: BlockExcEngine) {.async.} =
  ## Start the blockexc task
  ##

  await b.discovery.start()

  trace "Blockexc starting with concurrent tasks", tasks = b.concurrentTasks
  if b.blockexcRunning:
    warn "Starting blockexc twice"
    return

  b.blockexcRunning = true
  for i in 0..<b.concurrentTasks:
    b.blockexcTasks.add(blockexcTaskRunner(b))

proc stop*(b: BlockExcEngine) {.async.} =
  ## Stop the blockexc blockexc
  ##

  await b.discovery.stop()

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

  trace "NetworkStore stopped"

proc requestBlock*(
  b: BlockExcEngine,
  cid: Cid,
  timeout = DefaultBlockTimeout): Future[bt.Block] {.async.} =
  ## Request a block from remotes
  ##

  trace "Requesting block", cid, peers = b.peers.len

  if b.pendingBlocks.isInFlight(cid):
    trace "Request handle already pending", cid
    return await b.pendingBlocks.getWantHandle(cid, timeout)

  let
    blk = b.pendingBlocks.getWantHandle(cid, timeout)

  var
    peers = b.peers.selectCheapest(cid)

  if peers.len <= 0:
    trace "No cheapest peers, selecting first in list", cid
    peers = toSeq(b.peers) # Get any peer
    if peers.len <= 0:
      trace "No peers to request blocks from", cid
      b.discovery.queueFindBlocksReq(@[cid])
      return await blk

  let
    blockPeer = peers[0] # get cheapest

  proc blockHandleMonitor() {.async.} =
    try:
      trace "Monigoring block handle", cid
      b.pendingBlocks.setInFlight(cid, true)
      discard await blk
      trace "Block handle success", cid
    except CatchableError as exc:
      trace "Error block handle, disconnecting peer", cid, exc = exc.msg

      # TODO: really, this is just a quick and dirty way of
      # preventing hitting the same "bad" peer every time, however,
      # we might as well discover this on or next iteration, so
      # it doesn't mean that we're never talking to this peer again.
      # TODO: we need a lot more work around peer selection and
      # prioritization

      # drop unresponsive peer
      await b.network.switch.disconnect(blockPeer.id)

  trace "Sending block request to peer", peer = blockPeer.id, cid

  # monitor block handle
  asyncSpawn blockHandleMonitor()

  # request block
  await b.network.request.sendWantList(
    blockPeer.id,
    @[cid],
    wantType = WantType.WantBlock) # we want this remote to send us a block

  if (peers.len - 1) == 0:
    trace "No peers to send want list to", cid
    b.discovery.queueFindBlocksReq(@[cid])
    return await blk # no peers to send wants to

  # filter out the peer we've already requested from
  let remaining = peers[1..min(peers.high, b.peersPerRequest)]
  trace "Sending want list to remaining peers", count = remaining.len
  for p in remaining:
    if cid notin p.peerHave:
      # just send wants
      await b.network.request.sendWantList(
        p.id,
        @[cid],
        wantType = WantType.WantHave) # we only want to know if the peer has the block

  return await blk

proc blockPresenceHandler*(
  b: BlockExcEngine,
  peer: PeerId,
  blocks: seq[BlockPresence]) {.async.} =
  ## Handle block presence
  ##

  trace "Received presence update for peer", peer, blocks = blocks.len
  let
    peerCtx = b.peers.get(peer)
    wantList = toSeq(b.pendingBlocks.wantList)

  if peerCtx.isNil:
    return

  for blk in blocks:
    if presence =? Presence.init(blk):
      logScope:
        cid   = presence.cid
        have  = presence.have
        price = presence.price

      trace "Updating precense"
      peerCtx.setPresence(presence)

  let
    peerHave = peerCtx.peerHave
    dontWantCids = peerHave.filterIt(
      it notin wantList
    )

  if dontWantCids.len > 0:
    trace "Cleaning peer haves", peer, count = dontWantCids.len
    peerCtx.cleanPresence(dontWantCids)

  trace "Peer want/have", items = peerHave.len, wantList = wantList.len
  let
    wantCids = wantList.filterIt(
      it in peerHave
    )

  if wantCids.len > 0:
    trace "Getting blocks based on updated precense", peer, count = wantCids.len
    discard await allFinished(
      wantCids.mapIt(b.requestBlock(it)))
    trace "Requested blocks based on updated precense", peer, count = wantCids.len

  # if none of the connected peers report our wants in their have list,
  # fire up discovery
  b.discovery.queueFindBlocksReq(
    toSeq(b.pendingBlocks.wantList)
    .filter do(cid: Cid) -> bool:
      not b.peers.anyIt( cid in it.peerHave ))

proc scheduleTasks(b: BlockExcEngine, blocks: seq[bt.Block]) {.async.} =
  trace "Schedule a task for new blocks", items = blocks.len

  let
    cids = blocks.mapIt( it.cid )

  # schedule any new peers to provide blocks to
  for p in b.peers:
    for c in cids: # for each cid
      # schedule a peer if it wants at least one cid
      # and we have it in our local store
      if c in p.peerWants:
        if await (c in b.localStore):
          if b.scheduleTask(p):
            trace "Task scheduled for peer", peer = p.id
          else:
            trace "Unable to schedule task for peer", peer = p.id

          break # do next peer

proc resolveBlocks*(b: BlockExcEngine, blocks: seq[bt.Block]) {.async.} =
  ## Resolve pending blocks from the pending blocks manager
  ## and schedule any new task to be ran
  ##

  trace "Resolving blocks", blocks = blocks.len

  b.pendingBlocks.resolve(blocks)
  await b.scheduleTasks(blocks)
  b.discovery.queueProvideBlocksReq(blocks.mapIt( it.cid ))

proc payForBlocks(engine: BlockExcEngine,
                  peer: BlockExcPeerCtx,
                  blocks: seq[bt.Block]) {.async.} =
  trace "Paying for blocks", blocks = blocks.len

  let
    sendPayment = engine.network.request.sendPayment
    price = peer.price(blocks.mapIt(it.cid))

  if payment =? engine.wallet.pay(peer, price):
    trace "Sending payment for blocks", price
    await sendPayment(peer.id, payment)

proc blocksHandler*(
  b: BlockExcEngine,
  peer: PeerId,
  blocks: seq[bt.Block]) {.async.} =
  ## handle incoming blocks
  ##

  trace "Got blocks from peer", peer, len = blocks.len
  for blk in blocks:
    if isErr (await b.localStore.putBlock(blk)):
      trace "Unable to store block", cid = blk.cid

  await b.resolveBlocks(blocks)
  let
    peerCtx = b.peers.get(peer)

  if peerCtx != nil:
    # we don't care about this blocks anymore, lets cleanup the list
    await b.payForBlocks(peerCtx, blocks)
    peerCtx.cleanPresence(blocks.mapIt( it.cid ))

proc wantListHandler*(
  b: BlockExcEngine,
  peer: PeerId,
  wantList: WantList) {.async.} =
  ## Handle incoming want lists
  ##

  trace "Got want list for peer", peer, items = wantList.entries.len
  let peerCtx = b.peers.get(peer)
  if isNil(peerCtx):
    return

  var
    precense: seq[BlockPresence]

  for e in wantList.entries:
    let
      idx = peerCtx.peerWants.find(e)

    logScope:
      peer      = peerCtx.id
      cid       = e.cid
      wantType  = $e.wantType

    if idx < 0: # updating entry
      trace "Processing new want list entry", cid = e.cid

      let
        have = await e.cid in b.localStore
        price = @(
          b.pricing.get(Pricing(price: 0.u256))
          .price.toBytesBE)

      if not have and e.sendDontHave:
        trace "Adding dont have entry to precense response", cid = e.cid
        precense.add(
          BlockPresence(
          cid: e.cid.data.buffer,
          `type`: BlockPresenceType.DontHave,
          price: price))
      elif have and e.wantType == WantType.WantHave:
        trace "Adding have entry to precense response", cid = e.cid
        precense.add(
          BlockPresence(
          cid: e.cid.data.buffer,
          `type`: BlockPresenceType.Have,
          price: price))
      elif e.wantType == WantType.WantBlock:
        trace "Added entry to peer's want blocks list", cid = e.cid
        peerCtx.peerWants.add(e)
    else:
      # peer doesn't want this block anymore
      if e.cancel:
        trace "Removing entry from peer want list"
        peerCtx.peerWants.del(idx)
      else:
        trace "Updating entry in peer want list"
        # peer might want to ask for the same cid with
        # different want params
        peerCtx.peerWants[idx] = e # update entry

  if precense.len > 0:
    trace "Sending precense to remote", items = precense.len
    await b.network.request.sendPresence(peer, precense)

  if not b.scheduleTask(peerCtx):
    trace "Unable to schedule task for peer", peer

proc accountHandler*(
  engine: BlockExcEngine,
  peer: PeerId,
  account: Account) {.async.} =
  let context = engine.peers.get(peer)
  if context.isNil:
    return

  context.account = account.some

proc paymentHandler*(
  engine: BlockExcEngine,
  peer: PeerId,
  payment: SignedState) {.async.} =
  trace "Handling payments", peer

  without context =? engine.peers.get(peer).option and
          account =? context.account:
    trace "No context or account for peer", peer
    return

  if channel =? context.paymentChannel:
    let sender = account.address
    discard engine.wallet.acceptPayment(channel, Asset, sender, payment)
  else:
    context.paymentChannel = engine.wallet.acceptChannel(payment).option

proc setupPeer*(b: BlockExcEngine, peer: PeerId) {.async.} =
  ## Perform initial setup, such as want
  ## list exchange
  ##

  if peer notin b.peers:
    trace "Setting up new peer", peer
    b.peers.add(BlockExcPeerCtx(
      id: peer
    ))
    trace "Added peer", peers = b.peers.len

  # broadcast our want list, the other peer will do the same
  if b.pendingBlocks.len > 0:
    await b.network.request.sendWantList(
      peer, toSeq(b.pendingBlocks.wantList), full = true)

  if address =? b.pricing.?address:
    await b.network.request.sendAccount(peer, Account(address: address))

proc dropPeer*(b: BlockExcEngine, peer: PeerId) =
  ## Cleanup disconnected peer
  ##

  trace "Dropping peer", peer

  # drop the peer from the peers table
  b.peers.remove(peer)

proc taskHandler*(b: BlockExcEngine, task: BlockExcPeerCtx) {.gcsafe, async.} =
  trace "Handling task for peer", peer = task.id

  # Send to the peer blocks he wants to get,
  # if they present in our local store

  # TODO: There should be all sorts of accounting of
  # bytes sent/received here

  var
    wantsBlocks = task.peerWants.filterIt(
      it.wantType == WantType.WantBlock
    )

  if wantsBlocks.len > 0:
    trace "Got peer want blocks list", items = wantsBlocks.len

    wantsBlocks.sort(SortOrder.Descending)

    let
      blockFuts = await allFinished(wantsBlocks.mapIt(
        b.localStore.getBlock(it.cid)
      ))

    # Extract successfully received blocks
    let
      blocks = blockFuts
        .filterIt(it.completed and it.read.isOk)
        .mapIt(it.read.get)

    if blocks.len > 0:
      trace "Sending blocks to peer", peer = task.id, blocks = blocks.len
      await b.network.request.sendBlocks(
        task.id,
        blocks)

      trace "About to remove entries from peerWants", blocks = blocks.len, items = task.peerWants.len
      # Remove successfully sent blocks
      task.peerWants.keepIf(
        proc(e: Entry): bool =
          not blocks.anyIt( it.cid == e.cid )
      )
      trace "Removed entries from peerWants", items = task.peerWants.len

proc blockexcTaskRunner(b: BlockExcEngine) {.async.} =
  ## process tasks
  ##

  trace "Starting blockexc task runner"
  while b.blockexcRunning:
    let
      peerCtx = await b.taskQueue.pop()

    trace "Got new task from queue", peerId = peerCtx.id
    await b.taskHandler(peerCtx)

  trace "Exiting blockexc task runner"

proc new*(
  T: type BlockExcEngine,
  localStore: BlockStore,
  wallet: WalletRef,
  network: BlockExcNetwork,
  discovery: DiscoveryEngine,
  peerStore: PeerCtxStore,
  pendingBlocks: PendingBlocksManager,
  concurrentTasks = DefaultConcurrentTasks,
  peersPerRequest = DefaultMaxPeersPerRequest): T =

  let
    engine = BlockExcEngine(
      localStore: localStore,
      peers: peerStore,
      pendingBlocks: pendingBlocks,
      peersPerRequest: peersPerRequest,
      network: network,
      wallet: wallet,
      concurrentTasks: concurrentTasks,
      taskQueue: newAsyncHeapQueue[BlockExcPeerCtx](DefaultTaskQueueSize),
      discovery: discovery)

  proc peerEventHandler(peerId: PeerId, event: PeerEvent) {.async.} =
    if event.kind == PeerEventKind.Joined:
      await engine.setupPeer(peerId)
    else:
      engine.dropPeer(peerId)

  if not isNil(network.switch):
    network.switch.addPeerEventHandler(peerEventHandler, PeerEventKind.Joined)
    network.switch.addPeerEventHandler(peerEventHandler, PeerEventKind.Left)

  proc blockWantListHandler(
    peer: PeerId,
    wantList: WantList): Future[void] {.gcsafe.} =
    engine.wantListHandler(peer, wantList)

  proc blockPresenceHandler(
    peer: PeerId,
    presence: seq[BlockPresence]): Future[void] {.gcsafe.} =
    engine.blockPresenceHandler(peer, presence)

  proc blocksHandler(
    peer: PeerId,
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
