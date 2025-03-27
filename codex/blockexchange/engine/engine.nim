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
import pkg/libp2p/[cid, switch, multihash, multicodec]
import pkg/metrics
import pkg/stint
import pkg/questionable

import ../../rng
import ../../stores/blockstore
import ../../blocktype
import ../../utils
import ../../utils/exceptions
import ../../utils/trackedfutures
import ../../merkletree
import ../../logutils
import ../../manifest

import ../protobuf/blockexc
import ../protobuf/presence

import ../network
import ../peers

import ./payments
import ./discovery
import ./advertiser
import ./pendingblocks

export peers, pendingblocks, payments, discovery

logScope:
  topics = "codex blockexcengine"

declareCounter(
  codex_block_exchange_want_have_lists_sent, "codex blockexchange wantHave lists sent"
)
declareCounter(
  codex_block_exchange_want_have_lists_received,
  "codex blockexchange wantHave lists received",
)
declareCounter(
  codex_block_exchange_want_block_lists_sent, "codex blockexchange wantBlock lists sent"
)
declareCounter(
  codex_block_exchange_want_block_lists_received,
  "codex blockexchange wantBlock lists received",
)
declareCounter(codex_block_exchange_blocks_sent, "codex blockexchange blocks sent")
declareCounter(
  codex_block_exchange_blocks_received, "codex blockexchange blocks received"
)

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
    localStore*: BlockStore # Local block store for this instance
    network*: BlockExcNetwork # Petwork interface
    peers*: PeerCtxStore # Peers we're currently actively exchanging with
    taskQueue*: AsyncHeapQueue[BlockExcPeerCtx]
      # Peers we're currently processing tasks for
    concurrentTasks: int # Number of concurrent peers we're serving at any given time
    trackedFutures: TrackedFutures # Tracks futures of blockexc tasks
    blockexcRunning: bool # Indicates if the blockexc task is running
    pendingBlocks*: PendingBlocksManager # Blocks we're awaiting to be resolved
    wallet*: WalletRef # Nitro wallet for micropayments
    pricing*: ?Pricing # Optional bandwidth pricing
    discovery*: DiscoveryEngine
    advertiser*: Advertiser

  Pricing* = object
    address*: EthAddress
    price*: UInt256

# attach task scheduler to engine
proc scheduleTask(self: BlockExcEngine, task: BlockExcPeerCtx) {.gcsafe, raises: [].} =
  if self.taskQueue.pushOrUpdateNoWait(task).isOk():
    trace "Task scheduled for peer", peer = task.id
  else:
    warn "Unable to schedule task for peer", peer = task.id

proc blockexcTaskRunner(self: BlockExcEngine) {.async: (raises: []).}

proc start*(self: BlockExcEngine) {.async: (raises: []).} =
  ## Start the blockexc task
  ##

  await self.discovery.start()
  await self.advertiser.start()

  trace "Blockexc starting with concurrent tasks", tasks = self.concurrentTasks
  if self.blockexcRunning:
    warn "Starting blockexc twice"
    return

  self.blockexcRunning = true
  for i in 0 ..< self.concurrentTasks:
    let fut = self.blockexcTaskRunner()
    self.trackedFutures.track(fut)

proc stop*(self: BlockExcEngine) {.async: (raises: []).} =
  ## Stop the blockexc blockexc
  ##

  await self.trackedFutures.cancelTracked()
  await self.network.stop()
  await self.discovery.stop()
  await self.advertiser.stop()

  trace "NetworkStore stop"
  if not self.blockexcRunning:
    warn "Stopping blockexc without starting it"
    return

  self.blockexcRunning = false

  trace "NetworkStore stopped"

proc sendWantHave(
    self: BlockExcEngine, addresses: seq[BlockAddress], peers: seq[BlockExcPeerCtx]
): Future[void] {.async: (raises: [CancelledError]).} =
  for p in peers:
    let toAsk = addresses.filterIt(it notin p.peerHave)
    trace "Sending wantHave request", toAsk, peer = p.id
    await self.network.request.sendWantList(p.id, toAsk, wantType = WantType.WantHave)
    codex_block_exchange_want_have_lists_sent.inc()

proc sendWantBlock(
    self: BlockExcEngine, addresses: seq[BlockAddress], blockPeer: BlockExcPeerCtx
): Future[void] {.async: (raises: [CancelledError]).} =
  trace "Sending wantBlock request to", addresses, peer = blockPeer.id
  await self.network.request.sendWantList(
    blockPeer.id, addresses, wantType = WantType.WantBlock
  ) # we want this remote to send us a block
  codex_block_exchange_want_block_lists_sent.inc()

proc randomPeer(peers: seq[BlockExcPeerCtx]): BlockExcPeerCtx =
  Rng.instance.sample(peers)

proc downloadInternal(
    self: BlockExcEngine, address: BlockAddress
) {.async: (raises: []).} =
  logScope:
    address = address

  let handle = self.pendingBlocks.getWantHandle(address)
  trace "Downloading block"
  try:
    while address in self.pendingBlocks:
      logScope:
        retries = self.pendingBlocks.retries(address)
        interval = self.pendingBlocks.retryInterval

      if self.pendingBlocks.retriesExhausted(address):
        trace "Error retries exhausted"
        handle.fail(newException(RetriesExhaustedError, "Error retries exhausted"))
        break

      trace "Running retry handle"
      let peers = self.peers.getPeersForBlock(address)
      logScope:
        peersWith = peers.with.len
        peersWithout = peers.without.len

      trace "Peers for block"
      if peers.with.len > 0:
        self.pendingBlocks.setInFlight(address, true)
        await self.sendWantBlock(@[address], peers.with.randomPeer)
      else:
        self.pendingBlocks.setInFlight(address, false)
        if peers.without.len > 0:
          await self.sendWantHave(@[address], peers.without)
        self.discovery.queueFindBlocksReq(@[address.cidOrTreeCid])

      await (handle or sleepAsync(self.pendingBlocks.retryInterval))
      self.pendingBlocks.decRetries(address)

      if handle.finished:
        trace "Handle for block finished", failed = handle.failed
        break
  except CancelledError as exc:
    trace "Block download cancelled"
    if not handle.finished:
      await handle.cancelAndWait()
  except CatchableError as exc:
    warn "Error downloadloading block", exc = exc.msg
    if not handle.finished:
      handle.fail(exc)
  finally:
    self.pendingBlocks.setInFlight(address, false)

proc requestBlock*(
    self: BlockExcEngine, address: BlockAddress
): Future[?!Block] {.async: (raises: [CancelledError]).} =
  if address notin self.pendingBlocks:
    self.trackedFutures.track(self.downloadInternal(address))

  try:
    let handle = self.pendingBlocks.getWantHandle(address)
    success await handle
  except CancelledError as err:
    warn "Block request cancelled", address
    raise err
  except CatchableError as err:
    error "Block request failed", address, err = err.msg
    failure err

proc requestBlock*(
    self: BlockExcEngine, cid: Cid
): Future[?!Block] {.async: (raw: true, raises: [CancelledError]).} =
  self.requestBlock(BlockAddress.init(cid))

proc blockPresenceHandler*(
    self: BlockExcEngine, peer: PeerId, blocks: seq[BlockPresence]
) {.async: (raises: []).} =
  trace "Received block presence from peer", peer, blocks = blocks.mapIt($it)
  let
    peerCtx = self.peers.get(peer)
    ourWantList = toSeq(self.pendingBlocks.wantList)

  if peerCtx.isNil:
    return

  for blk in blocks:
    if presence =? Presence.init(blk):
      peerCtx.setPresence(presence)

  let
    peerHave = peerCtx.peerHave
    dontWantCids = peerHave.filterIt(it notin ourWantList)

  if dontWantCids.len > 0:
    peerCtx.cleanPresence(dontWantCids)

  let ourWantCids = ourWantList.filterIt(
    it in peerHave and not self.pendingBlocks.retriesExhausted(it) and
      not self.pendingBlocks.isInFlight(it)
  )

  for address in ourWantCids:
    self.pendingBlocks.setInFlight(address, true)
    self.pendingBlocks.decRetries(address)

  if ourWantCids.len > 0:
    trace "Peer has blocks in our wantList", peer, wants = ourWantCids
    if err =? catch(await self.sendWantBlock(ourWantCids, peerCtx)).errorOption:
      warn "Failed to send wantBlock to peer", peer, err = err.msg

proc scheduleTasks(
    self: BlockExcEngine, blocksDelivery: seq[BlockDelivery]
) {.async: (raises: [CancelledError]).} =
  let cids = blocksDelivery.mapIt(it.blk.cid)

  # schedule any new peers to provide blocks to
  for p in self.peers:
    for c in cids: # for each cid
      # schedule a peer if it wants at least one cid
      # and we have it in our local store
      if c in p.peerWantsCids:
        try:
          if await (c in self.localStore):
            # TODO: the try/except should go away once blockstore tracks exceptions
            self.scheduleTask(p)
            break
        except CancelledError as exc:
          warn "Checking local store canceled", cid = c, err = exc.msg
          return
        except CatchableError as exc:
          error "Error checking local store for cid", cid = c, err = exc.msg
          raiseAssert "Unexpected error checking local store for cid"

proc cancelBlocks(
    self: BlockExcEngine, addrs: seq[BlockAddress]
) {.async: (raises: [CancelledError]).} =
  ## Tells neighboring peers that we're no longer interested in a block.
  ##

  if self.peers.len == 0:
    return

  trace "Sending block request cancellations to peers",
    addrs, peers = self.peers.peerIds

  proc processPeer(peerCtx: BlockExcPeerCtx): Future[BlockExcPeerCtx] {.async.} =
    await self.network.request.sendWantCancellations(
      peer = peerCtx.id, addresses = addrs.filterIt(it in peerCtx)
    )

    return peerCtx

  try:
    let (succeededFuts, failedFuts) = await allFinishedFailed(
      toSeq(self.peers.peers.values).filterIt(it.peerHave.anyIt(it in addrs)).map(
        processPeer
      )
    )

    (await allFinished(succeededFuts)).mapIt(it.read).apply do(peerCtx: BlockExcPeerCtx):
      peerCtx.cleanPresence(addrs)

    if failedFuts.len > 0:
      warn "Failed to send block request cancellations to peers", peers = failedFuts.len
    else:
      trace "Block request cancellations sent to peers", peers = self.peers.len
  except CancelledError as exc:
    warn "Error sending block request cancellations", error = exc.msg
    raise exc
  except CatchableError as exc:
    warn "Error sending block request cancellations", error = exc.msg

proc resolveBlocks*(
    self: BlockExcEngine, blocksDelivery: seq[BlockDelivery]
) {.async: (raises: [CancelledError]).} =
  self.pendingBlocks.resolve(blocksDelivery)
  await self.scheduleTasks(blocksDelivery)
  await self.cancelBlocks(blocksDelivery.mapIt(it.address))

proc resolveBlocks*(
    self: BlockExcEngine, blocks: seq[Block]
) {.async: (raises: [CancelledError]).} =
  await self.resolveBlocks(
    blocks.mapIt(
      BlockDelivery(blk: it, address: BlockAddress(leaf: false, cid: it.cid))
    )
  )

proc payForBlocks(
    self: BlockExcEngine, peer: BlockExcPeerCtx, blocksDelivery: seq[BlockDelivery]
) {.async: (raises: [CancelledError]).} =
  let
    sendPayment = self.network.request.sendPayment
    price = peer.price(blocksDelivery.mapIt(it.address))

  if payment =? self.wallet.pay(peer, price):
    trace "Sending payment for blocks", price, len = blocksDelivery.len
    await sendPayment(peer.id, payment)

proc validateBlockDelivery(self: BlockExcEngine, bd: BlockDelivery): ?!void =
  if bd.address notin self.pendingBlocks:
    return failure("Received block is not currently a pending block")

  if bd.address.leaf:
    without proof =? bd.proof:
      return failure("Missing proof")

    if proof.index != bd.address.index:
      return failure(
        "Proof index " & $proof.index & " doesn't match leaf index " & $bd.address.index
      )

    without leaf =? bd.blk.cid.mhash.mapFailure, err:
      return failure("Unable to get mhash from cid for block, nested err: " & err.msg)

    without treeRoot =? bd.address.treeCid.mhash.mapFailure, err:
      return
        failure("Unable to get mhash from treeCid for block, nested err: " & err.msg)

    if err =? proof.verify(leaf, treeRoot).errorOption:
      return failure("Unable to verify proof for block, nested err: " & err.msg)
  else: # not leaf
    if bd.address.cid != bd.blk.cid:
      return failure(
        "Delivery cid " & $bd.address.cid & " doesn't match block cid " & $bd.blk.cid
      )

  return success()

proc blocksDeliveryHandler*(
    self: BlockExcEngine, peer: PeerId, blocksDelivery: seq[BlockDelivery]
) {.async: (raises: []).} =
  trace "Received blocks from peer", peer, blocks = (blocksDelivery.mapIt(it.address))

  var validatedBlocksDelivery: seq[BlockDelivery]
  for bd in blocksDelivery:
    logScope:
      peer = peer
      address = bd.address

    try:
      if err =? self.validateBlockDelivery(bd).errorOption:
        warn "Block validation failed", msg = err.msg
        continue

      if err =? (await self.localStore.putBlock(bd.blk)).errorOption:
        error "Unable to store block", err = err.msg
        continue

      if bd.address.leaf:
        without proof =? bd.proof:
          warn "Proof expected for a leaf block delivery"
          continue
        if err =? (
          await self.localStore.putCidAndProof(
            bd.address.treeCid, bd.address.index, bd.blk.cid, proof
          )
        ).errorOption:
          warn "Unable to store proof and cid for a block"
          continue
    except CatchableError as exc:
      warn "Error handling block delivery", error = exc.msg
      continue

    validatedBlocksDelivery.add(bd)

  codex_block_exchange_blocks_received.inc(validatedBlocksDelivery.len.int64)

  let peerCtx = self.peers.get(peer)
  if peerCtx != nil:
    if err =? catch(await self.payForBlocks(peerCtx, blocksDelivery)).errorOption:
      warn "Error paying for blocks", err = err.msg
      return

  if err =? catch(await self.resolveBlocks(validatedBlocksDelivery)).errorOption:
    warn "Error resolving blocks", err = err.msg
    return

proc wantListHandler*(
    self: BlockExcEngine, peer: PeerId, wantList: WantList
) {.async: (raises: []).} =
  trace "Received want list from peer", peer, wantList = wantList.entries.len

  let peerCtx = self.peers.get(peer)

  if peerCtx.isNil:
    return

  var
    presence: seq[BlockPresence]
    schedulePeer = false

  try:
    for e in wantList.entries:
      let idx = peerCtx.peerWants.findIt(it.address == e.address)

      logScope:
        peer = peerCtx.id
        address = e.address
        wantType = $e.wantType

      if idx < 0: # Adding new entry to peer wants
        let
          have =
            try:
              await e.address in self.localStore
            except CatchableError as exc:
              # TODO: should not be necessary once we have proper exception tracking on the BlockStore interface
              false
          price = @(self.pricing.get(Pricing(price: 0.u256)).price.toBytesBE)

        if e.cancel:
          trace "Received cancelation for untracked block, skipping",
            address = e.address
          continue

        trace "Processing want list entry", wantList = $e
        case e.wantType
        of WantType.WantHave:
          if have:
            presence.add(
              BlockPresence(
                address: e.address, `type`: BlockPresenceType.Have, price: price
              )
            )
          else:
            if e.sendDontHave:
              presence.add(
                BlockPresence(
                  address: e.address, `type`: BlockPresenceType.DontHave, price: price
                )
              )

          codex_block_exchange_want_have_lists_received.inc()
        of WantType.WantBlock:
          peerCtx.peerWants.add(e)
          schedulePeer = true
          codex_block_exchange_want_block_lists_received.inc()
      else: # Updating existing entry in peer wants
        # peer doesn't want this block anymore
        if e.cancel:
          trace "Canceling want for block", address = e.address
          peerCtx.peerWants.del(idx)
          trace "Canceled block request",
            address = e.address, len = peerCtx.peerWants.len
        else:
          if e.wantType == WantType.WantBlock:
            schedulePeer = true
          # peer might want to ask for the same cid with
          # different want params
          trace "Updating want for block", address = e.address
          peerCtx.peerWants[idx] = e # update entry
          trace "Updated block request",
            address = e.address, len = peerCtx.peerWants.len

    if presence.len > 0:
      trace "Sending presence to remote", items = presence.mapIt($it).join(",")
      await self.network.request.sendPresence(peer, presence)

    if schedulePeer:
      self.scheduleTask(peerCtx)
  except CancelledError as exc: #TODO: replace with CancelledError
    warn "Error processing want list", error = exc.msg

proc accountHandler*(
    self: BlockExcEngine, peer: PeerId, account: Account
) {.async: (raises: []).} =
  let context = self.peers.get(peer)
  if context.isNil:
    return

  context.account = account.some

proc paymentHandler*(
    self: BlockExcEngine, peer: PeerId, payment: SignedState
) {.async: (raises: []).} =
  trace "Handling payments", peer

  without context =? self.peers.get(peer).option and account =? context.account:
    trace "No context or account for peer", peer
    return

  if channel =? context.paymentChannel:
    let sender = account.address
    discard self.wallet.acceptPayment(channel, Asset, sender, payment)
  else:
    context.paymentChannel = self.wallet.acceptChannel(payment).option

proc setupPeer*(
    self: BlockExcEngine, peer: PeerId
) {.async: (raises: [CancelledError]).} =
  ## Perform initial setup, such as want
  ## list exchange
  ##

  trace "Setting up peer", peer

  if peer notin self.peers:
    trace "Setting up new peer", peer
    self.peers.add(BlockExcPeerCtx(id: peer))
    trace "Added peer", peers = self.peers.len

  # broadcast our want list, the other peer will do the same
  if self.pendingBlocks.wantListLen > 0:
    trace "Sending our want list to a peer", peer
    let cids = toSeq(self.pendingBlocks.wantList)
    await self.network.request.sendWantList(peer, cids, full = true)

  if address =? self.pricing .? address:
    trace "Sending account to peer", peer
    await self.network.request.sendAccount(peer, Account(address: address))

proc dropPeer*(self: BlockExcEngine, peer: PeerId) {.raises: [].} =
  ## Cleanup disconnected peer
  ##

  trace "Dropping peer", peer

  # drop the peer from the peers table
  self.peers.remove(peer)

proc taskHandler*(
    self: BlockExcEngine, task: BlockExcPeerCtx
) {.gcsafe, async: (raises: [CancelledError, RetriesExhaustedError]).} =
  # Send to the peer blocks he wants to get,
  # if they present in our local store

  # TODO: There should be all sorts of accounting of
  # bytes sent/received here

  var wantsBlocks =
    task.peerWants.filterIt(it.wantType == WantType.WantBlock and not it.inFlight)

  proc updateInFlight(addresses: seq[BlockAddress], inFlight: bool) =
    for peerWant in task.peerWants.mitems:
      if peerWant.address in addresses:
        peerWant.inFlight = inFlight

  if wantsBlocks.len > 0:
    # Mark wants as in-flight.
    let wantAddresses = wantsBlocks.mapIt(it.address)
    updateInFlight(wantAddresses, true)
    wantsBlocks.sort(SortOrder.Descending)

    proc localLookup(e: WantListEntry): Future[?!BlockDelivery] {.async.} =
      if e.address.leaf:
        (await self.localStore.getBlockAndProof(e.address.treeCid, e.address.index)).map(
          (blkAndProof: (Block, CodexProof)) =>
            BlockDelivery(
              address: e.address, blk: blkAndProof[0], proof: blkAndProof[1].some
            )
        )
      else:
        (await self.localStore.getBlock(e.address)).map(
          (blk: Block) =>
            BlockDelivery(address: e.address, blk: blk, proof: CodexProof.none)
        )

    let
      blocksDeliveryFut = await allFinished(wantsBlocks.map(localLookup))
      blocksDelivery = blocksDeliveryFut.filterIt(it.completed and it.value.isOk).mapIt:
        if bd =? it.value:
          bd
        else:
          raiseAssert "Unexpected error in local lookup"

    # All the wants that failed local lookup must be set to not-in-flight again.
    let
      successAddresses = blocksDelivery.mapIt(it.address)
      failedAddresses = wantAddresses.filterIt(it notin successAddresses)
    updateInFlight(failedAddresses, false)

    if blocksDelivery.len > 0:
      trace "Sending blocks to peer",
        peer = task.id, blocks = (blocksDelivery.mapIt(it.address))
      await self.network.request.sendBlocksDelivery(task.id, blocksDelivery)

      codex_block_exchange_blocks_sent.inc(blocksDelivery.len.int64)

      task.peerWants.keepItIf(it.address notin successAddresses)

proc blockexcTaskRunner(self: BlockExcEngine) {.async: (raises: []).} =
  ## process tasks
  ##

  trace "Starting blockexc task runner"
  try:
    while self.blockexcRunning:
      let peerCtx = await self.taskQueue.pop()
      await self.taskHandler(peerCtx)
  except CatchableError as exc:
    error "error running block exchange task", error = exc.msg

  info "Exiting blockexc task runner"

proc new*(
    T: type BlockExcEngine,
    localStore: BlockStore,
    wallet: WalletRef,
    network: BlockExcNetwork,
    discovery: DiscoveryEngine,
    advertiser: Advertiser,
    peerStore: PeerCtxStore,
    pendingBlocks: PendingBlocksManager,
    concurrentTasks = DefaultConcurrentTasks,
): BlockExcEngine =
  ## Create new block exchange engine instance
  ##

  let self = BlockExcEngine(
    localStore: localStore,
    peers: peerStore,
    pendingBlocks: pendingBlocks,
    network: network,
    wallet: wallet,
    concurrentTasks: concurrentTasks,
    trackedFutures: TrackedFutures(),
    taskQueue: newAsyncHeapQueue[BlockExcPeerCtx](DefaultTaskQueueSize),
    discovery: discovery,
    advertiser: advertiser,
  )

  proc peerEventHandler(
      peerId: PeerId, event: PeerEvent
  ): Future[void] {.gcsafe, async: (raises: [CancelledError]).} =
    if event.kind == PeerEventKind.Joined:
      await self.setupPeer(peerId)
    else:
      self.dropPeer(peerId)

  if not isNil(network.switch):
    network.switch.addPeerEventHandler(peerEventHandler, PeerEventKind.Joined)
    network.switch.addPeerEventHandler(peerEventHandler, PeerEventKind.Left)

  proc blockWantListHandler(
      peer: PeerId, wantList: WantList
  ): Future[void] {.async: (raises: []).} =
    self.wantListHandler(peer, wantList)

  proc blockPresenceHandler(
      peer: PeerId, presence: seq[BlockPresence]
  ): Future[void] {.async: (raises: []).} =
    self.blockPresenceHandler(peer, presence)

  proc blocksDeliveryHandler(
      peer: PeerId, blocksDelivery: seq[BlockDelivery]
  ): Future[void] {.async: (raises: []).} =
    self.blocksDeliveryHandler(peer, blocksDelivery)

  proc accountHandler(
      peer: PeerId, account: Account
  ): Future[void] {.async: (raises: []).} =
    self.accountHandler(peer, account)

  proc paymentHandler(
      peer: PeerId, payment: SignedState
  ): Future[void] {.async: (raises: []).} =
    self.paymentHandler(peer, payment)

  network.handlers = BlockExcHandlers(
    onWantList: blockWantListHandler,
    onBlocksDelivery: blocksDeliveryHandler,
    onPresence: blockPresenceHandler,
    onAccount: accountHandler,
    onPayment: paymentHandler,
  )

  return self
