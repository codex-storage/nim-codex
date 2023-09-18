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
import std/sugar

import pkg/chronos
import pkg/chronicles
import pkg/libp2p/[cid, switch, multihash]
import pkg/metrics
import pkg/stint

import ../../stores/blockstore
import ../../blocktype
import ../../utils
import ../../merkletree

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

declareCounter(codexBlockExchangeWantHaveListsSent, "codex blockexchange wantHave lists sent")
declareCounter(codexBlockExchangeWantHaveListsReceived, "codex blockexchange wantHave lists received")
declareCounter(codexBlockExchangeWantBlockListsSent, "codex blockexchange wantBlock lists sent")
declareCounter(codexBlockExchangeWantBlockListsReceived, "codex blockexchange wantBlock lists received")
declareCounter(codexBlockExchangeBlocksSent, "codex blockexchange blocks sent")
declareCounter(codexBlockExchangeBlocksReceived, "codex blockexchange blocks received")

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

  # BlockIter* = Iter[Block]

# TODO check usages
proc contains*(a: AsyncHeapQueue[Entry], b: Cid): bool =
  ## Convenience method to check for entry prepense
  ##

  a.anyIt( not it.address.leaf and it.address.cid == b )

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
  for task in b.blockexcTasks:
    if not task.finished:
      trace "Awaiting task to stop"
      await task.cancelAndWait()
      trace "Task stopped"

  trace "NetworkStore stopped"


proc sendWantHave(b: BlockExcEngine, address: BlockAddress, selectedPeer: BlockExcPeerCtx, peers: seq[BlockExcPeerCtx]): Future[void] {.async.} =
  trace "Sending wantHave request to peers", address = $address #TODO
  for p in peers:
    if p != selectedPeer:
      if address notin p.peerHave:
        trace " wantHave > ", peer = p.id
        await b.network.request.sendWantList(
          p.id,
          @[address],
          wantType = WantType.WantHave) # we only want to know if the peer has the block

proc sendWantBlock(b: BlockExcEngine, address: BlockAddress, blockPeer: BlockExcPeerCtx): Future[void] {.async.} =
  trace "Sending wantBlock request to", peer = blockPeer.id, address = $address #TODO
  await b.network.request.sendWantList(
    blockPeer.id,
    @[address],
    wantType = WantType.WantBlock) # we want this remote to send us a block

proc findCheapestPeerForBlock(b: BlockExcEngine, cheapestPeers: seq[BlockExcPeerCtx]): ?BlockExcPeerCtx =
  if cheapestPeers.len <= 0:
    trace "No cheapest peers, selecting first in list"
    let
      peers = toSeq(b.peers) # Get any peer
    if peers.len <= 0:
      return none(BlockExcPeerCtx)
    return some(peers[0])
  return some(cheapestPeers[0]) # get cheapest


# TODO think about this one
# proc requestBlock*(
#   b: BlockExcEngine,
#   treeCid: Cid,
#   index: Natural,
#   timeout = DefaultBlockTimeout
# ): Future[Block] {.async.} =
#   let blockFuture = b.pendingBlocks.getWantHandle(treeCid, index, leavesCount, merkleRoot, timeout)

#   if b.pendingBlocks.isInFlight(treeCid, index):
#     return await blockFuture

#   let peers = b.peers.selectCheapest(cid)
#   if peers.len == 0:
#     b.discovery.queueFindBlocksReq(@[cid])
#     return await blockFuture
#   else:
#     b.pendingBlocks.setInFlight(treeCid, index)

#     peer = peers[index mod peers.len] # round robin
#     await b.sendWantBlock(treeCid, index, peer)
#     await b.sendWantHave(treeCid, index, peer, toSeq(b.peers))
    # return await blockFuture
# TODO think about this one

proc requestBlock(
  b: BlockExcEngine,
  treeReq: TreeReq,
  index: Natural,
  timeout = DefaultBlockTimeout
): Future[Block] {.async.} =
  let 
    blockFuture = treeReq.getWantHandle(index, timeout)
    address = BlockAddress(leaf: true, treeCid: treeReq.treeCid, index: index)

  if treeReq.isInFlight(index):
    return await blockFuture

  let peers = b.peers.selectCheapest(treeReq.treeCid)
  if peers.len == 0:
    b.discovery.queueFindBlocksReq(@[treeReq.treeCid])
    return await blockFuture
  else:
    treeReq.setInFlight(index)
    let peer = peers[index mod peers.len] # round robin
    await b.sendWantBlock(address, peer)
    await b.sendWantHave(address, peer, toSeq(b.peers))
    return await blockFuture

proc requestBlocks*(
  b: BlockExcEngine,
  treeCid: Cid,
  leavesCount: Natural,
  merkleRoot: MultiHash,
  timeout = DefaultBlockTimeout
): ?!Iter[Block] =
  without treeReq =? b.pendingBlocks.getOrPutTreeReq(treeCid, leavesCount, merkleRoot), err:
    return failure(err)

  var
    iter = Iter[Block]()
    index = 0

  proc next(): Future[Block] =
    if index < leavesCount:
      inc index
      if index >= leavesCount:
        iter.finished = true
      return b.requestBlock(treeReq, index - 1, timeout)
    else:
      let fut = newFuture[Block]("chronos.race()") #TODO fixit
      fut.fail(newException(CodexError, "No more elements for tree with cid " & $treeCid))
      return fut

  iter.next = next
  return success(iter)


# iterator requestBlocks*(
#   b: BlockExcEngine,
#   treeCid: Cid,
#   leavesCount: Natural,
#   merkleRoot: MultiHash,
#   timeout = DefaultBlockTimeout
# ): Future[Block] {.async.} =
#   ## 
#   ## 
#   without treeReq =? b.pendingBlocks.getOrPutTreeReq(treeCid, leavesCount, merkleRoot), err:
#     return err

#   for index in 0..<leavesCount:
#     yield await b.requestBlock(treeReq, index, timeout)

proc requestBlock*(
  b: BlockExcEngine,
  cid: Cid,
  timeout = DefaultBlockTimeout): Future[Block] {.async.} =
  trace "Begin block request", cid, peers = b.peers.len

  if b.pendingBlocks.isInFlight(cid):
    trace "Request handle already pending", cid
    return await b.pendingBlocks.getWantHandle(cid, timeout)

  let
    blk = b.pendingBlocks.getWantHandle(cid, timeout)
    address = BlockAddress(leaf: false, cid: cid)

  trace "Selecting peers who have", cid
  var
    peers = b.peers.selectCheapest(cid)

  without blockPeer =? b.findCheapestPeerForBlock(peers):
      trace "No peers to request blocks from. Queue discovery...", cid
      b.discovery.queueFindBlocksReq(@[cid])
      return await blk

  proc blockHandleMonitor() {.async.} =
    try:
      trace "Monitoring block handle", cid
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

  # monitor block handle
  asyncSpawn blockHandleMonitor()

  await b.sendWantBlock(address, blockPeer)

  codexBlockExchangeWantBlockListsSent.inc()

  if (peers.len - 1) == 0:
    trace "No peers to send want list to", cid
    b.discovery.queueFindBlocksReq(@[cid])
    return await blk

  await b.sendWantHave(address, blockPeer, toSeq(b.peers))

  codexBlockExchangeWantHaveListsSent.inc()

  return await blk

proc blockPresenceHandler*(
  b: BlockExcEngine,
  peer: PeerId,
  blocks: seq[BlockPresence]) {.async.} =
  trace "Received presence update for peer", peer, blocks = blocks.len

  let
    peerCtx = b.peers.get(peer)
    wantList = toSeq(b.pendingBlocks.wantList)

  if peerCtx.isNil:
    return

  for blk in blocks:
    if presence =? Presence.init(blk):
      logScope:
        address   = $presence.address
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
    peerCtx.cleanPresence(dontWantCids)

  let
    wantCids = wantList.filterIt(
      it in peerHave
    )

  if wantCids.len > 0:
    trace "Peer has blocks in our wantList", peer, count = wantCids.len
    discard await allFinished(
      wantCids.mapIt(b.sendWantBlock(it, peerCtx)))

  # if none of the connected peers report our wants in their have list,
  # fire up discovery
  b.discovery.queueFindBlocksReq(
    toSeq(b.pendingBlocks.wantListCids)
    .filter do(cid: Cid) -> bool:
      not b.peers.anyIt( cid in it.peerHaveCids ))

proc scheduleTasks(b: BlockExcEngine, blocksDelivery: seq[BlockDelivery]) {.async.} =
  trace "Schedule a task for new blocks", items = blocksDelivery.len

  let
    cids = blocksDelivery.mapIt( it.blk.cid )

  # schedule any new peers to provide blocks to
  for p in b.peers:
    for c in cids: # for each cid
      # schedule a peer if it wants at least one cid
      # and we have it in our local store
      if c in p.peerWantsCids:
        if await (c in b.localStore): # TODO this is cruical, though indirect
          if b.scheduleTask(p):
            trace "Task scheduled for peer", peer = p.id
          else:
            trace "Unable to schedule task for peer", peer = p.id

          break # do next peer

proc resolveBlocks*(b: BlockExcEngine, blocksDelivery: seq[BlockDelivery]) {.async.} =
  trace "Resolving blocks", blocks = blocksDelivery.len

  b.pendingBlocks.resolve(blocksDelivery)
  await b.scheduleTasks(blocksDelivery)
  b.discovery.queueProvideBlocksReq(blocksDelivery.mapIt( it.blk.cid ))

proc resolveBlocks*(b: BlockExcEngine, blocks: seq[Block]) {.async.} =
  await b.resolveBlocks(blocks.mapIt(BlockDelivery(blk: it, address: BlockAddress(leaf: false, cid: it.cid))))

proc payForBlocks(engine: BlockExcEngine,
                  peer: BlockExcPeerCtx,
                  blocksDelivery: seq[BlockDelivery]) {.async.} =
  trace "Paying for blocks", len = blocksDelivery.len

  let
    sendPayment = engine.network.request.sendPayment
    price = peer.price(blocksDelivery.mapIt(it.address))

  if payment =? engine.wallet.pay(peer, price):
    trace "Sending payment for blocks", price
    await sendPayment(peer.id, payment)

proc blocksDeliveryHandler*(
  b: BlockExcEngine,
  peer: PeerId,
  blocksDelivery: seq[BlockDelivery]) {.async.} =
  trace "Got blocks from peer", peer, len = blocksDelivery.len

  for bd in blocksDelivery:
    if isErr (await b.localStore.putBlock(bd.blk)):
      trace "Unable to store block", cid = bd.blk.cid

  await b.resolveBlocks(blocksDelivery)
  codexBlockExchangeBlocksReceived.inc(blocksDelivery.len.int64)

  let
    peerCtx = b.peers.get(peer)

  if peerCtx != nil:
    await b.payForBlocks(peerCtx, blocksDelivery)
    ## shouldn't we remove them from the want-list instead of this:
    peerCtx.cleanPresence(blocksDelivery.mapIt( it.address ))

proc wantListHandler*(
  b: BlockExcEngine,
  peer: PeerId,
  wantList: WantList) {.async.} =
  trace "Got wantList for peer", peer, items = wantList.entries.len
  let
    peerCtx = b.peers.get(peer)
  if isNil(peerCtx):
    return

  var
    presence: seq[BlockPresence]

  for e in wantList.entries:
    let
      idx = peerCtx.peerWants.find(e)

    logScope:
      peer      = peerCtx.id
      # cid       = e.cid
      wantType  = $e.wantType

    if idx < 0: # updating entry
      trace "Processing new want list entry", address = $e.address

      let
        have = await e.address in b.localStore
        price = @(
          b.pricing.get(Pricing(price: 0.u256))
          .price.toBytesBE)

      if e.wantType == WantType.WantHave:
        codexBlockExchangeWantHaveListsReceived.inc()

      if not have and e.sendDontHave:
        trace "Adding dont have entry to presence response", address = $e.address
        presence.add(
          BlockPresence(
          address: e.address,
          `type`: BlockPresenceType.DontHave,
          price: price))
      elif have and e.wantType == WantType.WantHave:
        trace "Adding have entry to presence response", address = $e.address
        presence.add(
          BlockPresence(
          address: e.address,
          `type`: BlockPresenceType.Have,
          price: price))
      elif e.wantType == WantType.WantBlock:
        trace "Added entry to peer's want blocks list", address = $e.address
        peerCtx.peerWants.add(e)
        codexBlockExchangeWantBlockListsReceived.inc()
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

  if presence.len > 0:
    trace "Sending presence to remote", items = presence.len
    await b.network.request.sendPresence(peer, presence)

  trace "Scheduling a task for this peer, to look over their want-list", peer
  if not b.scheduleTask(peerCtx):
    trace "Unable to schedule task for peer", peer

proc accountHandler*(
  engine: BlockExcEngine,
  peer: PeerId,
  account: Account) {.async.} =
  let
    context = engine.peers.get(peer)
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
    let
      sender = account.address
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

  trace "wantsBlocks", peer = task.id, n = wantsBlocks.len
  if wantsBlocks.len > 0:
    trace "Got peer want blocks list", items = wantsBlocks.len

    wantsBlocks.sort(SortOrder.Descending)

    proc localLookup(e: Entry): Future[?!BlockDelivery] {.async.} =
      if e.address.leaf:
        (await b.localStore.getBlockAndProof(e.address.treeCid, e.address.index)).map(
          (blkAndProof: (Block, MerkleProof)) => 
            BlockDelivery(address: e.address, blk: blkAndProof[0], proof: blkAndProof[1])
            # pb.Block(cid: blk.cid, blk.data, leaf: true, treeCid: e.treeCid, proof: proof)
        )
      else:
        (await b.localStore.getBlock(e.address.cid)).map(
          (blk: Block) => BlockDelivery(address: e.address, blk: blk)
        )

    let
      blocksDeliveryFut = await allFinished(wantsBlocks.map(localLookup))

    # Extract successfully received blocks
    let
      blocksDelivery = blocksDeliveryFut
        .filterIt(it.completed and it.read.isOk)
        .mapIt(it.read.get)

    if blocksDelivery.len > 0:
      trace "Sending blocks to peer", peer = task.id, blocks = blocksDelivery.len
      await b.network.request.sendBlocksDelivery(
        task.id,
        blocksDelivery
      )

      codexBlockExchangeBlocksSent.inc(blocksDelivery.len.int64)

      trace "About to remove entries from peerWants", blocks = blocksDelivery.len, items = task.peerWants.len
      # Remove successfully sent blocks
      task.peerWants.keepIf(
        proc(e: Entry): bool =
          not blocksDelivery.anyIt( it.address == e.address )
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
    peersPerRequest = DefaultMaxPeersPerRequest
): BlockExcEngine =
  ## Create new block exchange engine instance
  ##

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

  proc blocksDeliveryHandler(
    peer: PeerId,
    blocksDelivery: seq[BlockDelivery]): Future[void] {.gcsafe.} =
    engine.blocksDeliveryHandler(peer, blocksDelivery)

  proc accountHandler(peer: PeerId, account: Account): Future[void] {.gcsafe.} =
    engine.accountHandler(peer, account)

  proc paymentHandler(peer: PeerId, payment: SignedState): Future[void] {.gcsafe.} =
    engine.paymentHandler(peer, payment)

  network.handlers = BlockExcHandlers(
    onWantList: blockWantListHandler,
    onBlocksDelivery: blocksDeliveryHandler,
    onPresence: blockPresenceHandler,
    onAccount: accountHandler,
    onPayment: paymentHandler)

  return engine
