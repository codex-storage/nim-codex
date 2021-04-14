## Nim-Dagger
## Copyright (c) 2021 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import std/sequtils
import std/algorithm

import pkg/chronos
import pkg/chronicles
import pkg/libp2p
import pkg/libp2p/errors

import ./protobuf/bitswap as pb
import ../blocktype as bt
import ../stores/blockstore
import ../utils/asyncheapqueue

import ./network
import ./pendingblocks
import ./peercontext
import ./engine/payments

export peercontext

logScope:
  topics = "dagger bitswap engine"

const
  DefaultTimeout* = 5.seconds
  DefaultMaxPeersPerRequest* = 10

type
  TaskHandler* = proc(task: BitswapPeerCtx): Future[void] {.gcsafe.}
  TaskScheduler* = proc(task: BitswapPeerCtx): bool {.gcsafe.}

  BitswapEngine* = ref object of RootObj
    localStore*: BlockStore                     # where we localStore blocks for this instance
    peers*: seq[BitswapPeerCtx]                 # peers we're currently actively exchanging with
    wantList*: seq[Cid]                         # local wants list
    pendingBlocks*: PendingBlocksManager        # blocks we're awaiting to be resolved
    peersPerRequest: int                        # max number of peers to request from
    scheduleTask*: TaskScheduler                # schedule a new task with the task runner
    request*: BitswapRequest                    # bitswap network requests
    wallet*: Wallet                             # nitro wallet for micropayments
    pricing*: ?Pricing                          # optional bandwidth pricing

proc contains*(a: AsyncHeapQueue[Entry], b: Cid): bool =
  ## Convenience method to check for entry prepense
  ##

  a.anyIt( it.cid == b )

proc getPeerCtx*(b: BitswapEngine, peerId: PeerID): BitswapPeerCtx =
  ## Get the peer's context
  ##

  let peer = b.peers.filterIt( it.id == peerId )
  if peer.len > 0:
    return peer[0]

proc requestBlocks*(
  b: BitswapEngine,
  cids: seq[Cid],
  timeout = DefaultTimeout): seq[Future[bt.Block]] =
  ## Request a block from remotes
  ##

  # no Cids to request
  if cids.len == 0:
    return

  if b.peers.len <= 0:
    warn "No peers to request blocks from"
    # TODO: run discovery here to get peers for the block
    return

  var blocks: seq[Future[bt.Block]]
  for c in cids:
    if c notin b.pendingBlocks:
      # install events to await blocks incoming from different sources
      blocks.add(
        b.pendingBlocks.addOrAwait(c).wait(timeout))

  proc cmp(a, b: BitswapPeerCtx): int =
    if a.debtRatio == b.debtRatio:
      0
    elif a.debtRatio > b.debtRatio:
      1
    else:
      -1

  # sort the peers so that we request
  # the blocks from a peer with the lowest
  # debt ratio
  var sortedPeers = b.peers.sorted(
    cmp
  )

  # get the first peer with at least one (any)
  # matching cid
  var blockPeer: BitswapPeerCtx
  for i, p in sortedPeers:
    let has = cids.anyIt(
      it in p.peerHave
    )

    if has:
      blockPeer = p
      break

  # didn't find any peer with matching cids
  # use the first one in the sorted array
  if isNil(blockPeer):
    blockPeer = sortedPeers[0]

  sortedPeers.keepItIf(
    it != blockPeer
  )

  trace "Requesting blocks from peer", peer = blockPeer.id, len = cids.len
  # request block
  b.request.sendWantList(
    blockPeer.id,
    cids,
    wantType = WantType.wantBlock) # we want this remote to send us a block

  if sortedPeers.len == 0:
    return blocks # no peers to send wants to

  template sendWants(ctx: BitswapPeerCtx) =
    # just send wants
    b.request.sendWantList(
      ctx.id,
      cids.filterIt( it notin ctx.peerHave ), # filter out those that we already know about
      wantType = WantType.wantHave) # we only want to know if the peer has the block

  # filter out the peer we've already requested from
  var stop = sortedPeers.high
  if stop > b.peersPerRequest: stop = b.peersPerRequest
  trace "Sending want list requests to remaining peers", count = stop + 1
  for p in sortedPeers[0..stop]:
    sendWants(p)

  return blocks

proc blockPresenceHandler*(
  b: BitswapEngine,
  peer: PeerID,
  presence: seq[BlockPresence]) =
  ## Handle block presence
  ##

  let peerCtx = b.getPeerCtx(peer)
  if isNil(peerCtx):
    return

  for blk in presence:
    let cid = Cid.init(blk.cid).get()
    if cid notin peerCtx.peerHave:
      if blk.type == BlockPresenceType.presenceHave:
        peerCtx.peerHave.add(cid)

proc scheduleTasks(b: BitswapEngine, blocks: seq[bt.Block]) =
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

proc resolveBlocks*(b: BitswapEngine, blocks: seq[bt.Block]) =
  ## Resolve pending blocks from the pending blocks manager
  ## and schedule any new task to be ran
  ##

  trace "Resolving blocks"
  b.pendingBlocks.resolve(blocks)
  b.scheduleTasks(blocks)

proc payForBlocks(engine: BitswapEngine,
                  peer: BitswapPeerCtx,
                  blocks: seq[bt.Block]) =
  let sendPayment = engine.request.sendPayment
  if sendPayment.isNil:
    return

  var amountOfBytes = 0
  for blck in blocks:
    amountOfBytes += blck.data.len

  if payment =? engine.wallet.pay(peer, amountOfBytes):
    sendPayment(peer.id, payment)

proc blocksHandler*(
  b: BitswapEngine,
  peer: PeerID,
  blocks: seq[bt.Block]) =
  ## handle incoming blocks
  ##

  trace "Got blocks from peer", peer, len = blocks.len
  b.localStore.putBlocks(blocks)
  b.resolveBlocks(blocks)

  let peerCtx = b.getPeerCtx(peer)
  if peerCtx != nil:
    b.payForBlocks(peerCtx, blocks)

proc wantListHandler*(
  b: BitswapEngine,
  peer: PeerID,
  wantList: WantList) =
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
    if e.sendDontHave and not(b.localStore.hasBlock(e.cid)):
      dontHaves.add(e.cid)

  # send don't have's to remote
  if dontHaves.len > 0:
    b.request.sendPresence(
      peer,
      dontHaves.mapIt(
        BlockPresence(
          cid: it.data.buffer,
          `type`: BlockPresenceType.presenceDontHave)))

  if not b.scheduleTask(peerCtx):
    trace "Unable to schedule task for peer", peer

proc pricingHandler*(engine: BitswapEngine, peer: PeerID, pricing: Pricing) =
  let context = engine.getPeerCtx(peer)
  if context.isNil:
    return

  context.pricing = pricing.some

proc setupPeer*(b: BitswapEngine, peer: PeerID) =
  ## Perform initial setup, such as want
  ## list exchange
  ##

  trace "Setting up new peer", peer
  if peer notin b.peers:
    b.peers.add(BitswapPeerCtx(
      id: peer
    ))

  # broadcast our want list, the other peer will do the same
  if b.wantList.len > 0:
    b.request.sendWantList(peer, b.wantList, full = true)

  if b.pricing.isSome:
    b.request.sendPricing(peer, b.pricing.get)

proc dropPeer*(b: BitswapEngine, peer: PeerID) =
  ## Cleanup disconnected peer
  ##

  trace "Dropping peer", peer

  # drop the peer from the peers table
  b.peers.keepItIf( it.id != peer )

proc taskHandler*(b: BitswapEngine, task: BitswapPeerCtx) {.gcsafe, async.} =
  trace "Handling task for peer", peer = task.id

  var wantsBlocks = newAsyncHeapQueue[Entry](queueType = QueueType.Max)
  # get blocks and wants to send to the remote
  for e in task.peerWants:
    if e.wantType == WantType.wantBlock:
      await wantsBlocks.push(e)

  # TODO: There should be all sorts of accounting of
  # bytes sent/received here
  if wantsBlocks.len > 0:
    let blocks = await b.localStore.getBlocks(
      wantsBlocks.mapIt(
        it.cid
    ))

    if blocks.len > 0:
      b.request.sendBlocks(task.id, blocks)

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
      wants.add(
        BlockPresence(
            cid: e.`block`,
            `type`: if b.localStore.hasBlock(e.cid):
                BlockPresenceType.presenceHave
              else:
                BlockPresenceType.presenceDontHave
        ))

  if wants.len > 0:
    b.request.sendPresence(task.id, wants)

proc new*(
  T: type BitswapEngine,
  localStore: BlockStore,
  wallet: Wallet,
  request: BitswapRequest = BitswapRequest(),
  scheduleTask: TaskScheduler = nil,
  peersPerRequest = DefaultMaxPeersPerRequest): T =

  proc taskScheduler(task: BitswapPeerCtx): bool =
    if not isNil(scheduleTask):
      return scheduleTask(task)

  let b = BitswapEngine(
    localStore: localStore,
    pendingBlocks: PendingBlocksManager.new(),
    peersPerRequest: peersPerRequest,
    scheduleTask: taskScheduler,
    request: request,
    wallet: wallet
  )

  return b
