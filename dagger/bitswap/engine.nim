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

const
  DefaultTimeout* = 500.milliseconds
  DefaultMaxPeersPerRequest* = 10

type
  TaskHandler* = proc(task: BitswapPeerCtx): Future[void] {.gcsafe.}
  TaskScheduler* = proc(task: BitswapPeerCtx): bool {.gcsafe.}

  BitswapPeerCtx* = ref object of RootObj
    id*: PeerID
    peerHave*: seq[Cid]                # remote peers have lists
    peerWants*: AsyncHeapQueue[Entry]  # remote peers want lists
    bytesSent*: int                    # bytes sent to remote
    bytesRecv*: int                    # bytes received from remote
    exchanged*: int                    # times peer has exchanged with us
    lastExchange*: Moment              # last time peer has exchanged with us

  BitswapEngine* = ref object of RootObj
    localStore*: BlockStore                     # where we localStore blocks for this instance
    peers*: seq[BitswapPeerCtx]                 # peers we're currently activelly exchanging with
    wantList*: seq[Cid]                         # local wants list
    pendingBlocks*: PendingBlocksManager        # blocks we're awaiting to be resolved
    peersPerRequest: int                        # max number of peers to request from
    scheduleTask*: TaskScheduler                # schedule a new task with the task runnuer
    request*: BitswapRequest                    # bitswap network requests

proc contains*(a: AsyncHeapQueue[Entry], b: Cid): bool =
  ## Convenience method to check for entry precense
  ##

  a.filterIt( it.cid == b ).len > 0

proc contains*(a: openarray[BitswapPeerCtx], b: PeerID): bool =
  ## Convenience method to check for peer precense
  ##

  a.filterIt( it.id == b ).len > 0

proc debtRatio*(b: BitswapPeerCtx): float =
  b.bytesSent / (b.bytesRecv + 1)

proc `<`*(a, b: BitswapPeerCtx): bool =
  a.debtRatio < b.debtRatio

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

proc blocksHandler*(
  b: BitswapEngine,
  peer: PeerID,
  blocks: seq[bt.Block]) =
  ## handle incoming blocks
  ##

  b.localStore.putBlocks(blocks)
  b.pendingBlocks.resolve(blocks)

proc wantListHandler*(
  b: BitswapEngine,
  peer: PeerID,
  wantList: WantList) =
  ## Handle incoming want lists
  ##

  trace "got want list from peer", peer

  let peerCtx = b.getPeerCtx(peer)
  if isNil(peerCtx):
    return

  var dontHaves: seq[Cid]
  let entries = wantList.entries
  for e in entries:
    if e.cid in peerCtx.peerWants:
      # peer doesn't want this block anymore
      if e.cancel:
        peerCtx.peerWants.delete(e)
        continue
    else:
      if peerCtx.peerWants.pushOrUpdateNoWait(e).isErr:
        trace "Cant add want cid", cid = $e.cid

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

proc setupPeer*(b: BitswapEngine, peer: PeerID) =
  ## Perform initial setup, such as want
  ## list exchange
  ##

  if peer notin b.peers:
    b.peers.add(BitswapPeerCtx(
      id: peer,
      peerWants: newAsyncHeapQueue[Entry](queueType = QueueType.Max)
    ))

  # broadcast our want list, the other peer will do the same
  b.request.sendWantList(peer, b.wantList, full = true)

proc dropPeer*(b: BitswapEngine, peer: PeerID) =
  ## Cleanup disconnected peer
  ##

  # drop the peer from the peers table
  b.peers.keepItIf( it.id != peer )

proc taskHandler*(b: BitswapEngine, task: BitswapPeerCtx) {.gcsafe, async.} =
  var wantsBlocks, wantsWants: seq[Entry]
  # get blocks and wants to send to the remote
  while task.peerWants.len > 0:
    let want = task.peerWants.popNoWait()
    if want.isOk:
      let e = want.get()
      if e.wantType == WantType.wantBlock:
        wantsBlocks.add(e)
      else:
        wantsWants.add(e)

  # TODO: There should be all sorts of accounting of
  # bytes sent/received here
  if wantsBlocks.len > 0:
    let blocks = await b.localStore.getBlocks(
      wantsBlocks.mapIt(
        it.cid
    ))

    b.request.sendBlocks(task.id, blocks)

  if wantsWants.len > 0:
    let wants = wantsWants.mapIt(
        BlockPresence(
          cid: it.`block`,
          `type`: if b.localStore.hasBlock(it.cid):
              BlockPresenceType.presenceHave
            else:
              BlockPresenceType.presenceDontHave
        )
    )

    b.request.sendPresence(
      task.id, wants)

proc new*(
  T: type BitswapEngine,
  localStore: BlockStore,
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
  )

  proc onBlocks(evt: BlockStoreChangeEvt) =
    if evt.kind != ChangeType.Added:
      return

    proc resolveBlocks() {.async.} =
      let blocks = await b.localStore.getBlocks(evt.cids)
      b.pendingBlocks.resolve(blocks)

    asyncSpawn resolveBlocks()

    # schedule any new peers to provide blocks to
    for p in b.peers:
      for c in evt.cids:        # for each block
          if c in p.peerWants:  # see if a peer wants at least one cid
            if not b.scheduleTask(p):
              # TODO: This breaks with
              #`chronicles.nim(336, 21) Error: undeclared identifier: 'activeChroniclesStream'`
              # trace "Unable to schedule a on new blocks for peer", peer = p.id
              discard
            break # do next peer

  localStore.addChangeHandler(onBlocks, ChangeType.Added)
  return b
