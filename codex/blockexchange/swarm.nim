import std/algorithm
import std/intsets

import pkg/chronos
import pkg/libp2p
import pkg/questionable

import ./network/network

import ../blocktype
import ../discovery
import ../manifest
import ../merkletree/codex
import ../stores
import ../utils/trackedfutures

logScope:
  topics = "blockexchange swarm"

const
  DefaultMinNeighbors = 40
  DefaultMaxNeighbors = 80
  DefaultMaxPendingRequests = 100
  DefaultRefreshPeerCount = 2
  DefaultAdvertisementInterval = 15.minutes
  DefaultMaxBlocksPerBatch = 160 # that's about 10 megabytes per transfer

type
  BlockState* = object
    requests: int
    completed: bool

  SwarmPeerCtx* = object
    id*: PeerId
    # Blocks peer has
    blocks*: seq[bool]
    # Number of block requests outstanding to peer
    pendingRequests: int
    # Last time we refreshed block knowledge from peer
    lastRefresh: Moment
    # Pending knowledge update request
    blockKnowledgeRequest: Future[void].Raising([CancelledError])

  Swarm* = ref object of RootObj # Dataset Manifest
    manifest: Manifest
    # Min/max neighbors into swarm
    minNeighbors: int
    maxNeighbors: int
    # Max pending requests per peer
    maxPendingRequests: int
    # How many blocks to send at once, at most, to a peer
    maxBlocksPerBatch: int
    # Download state for blocks
    blocks: seq[BlockState]
    downloadedBlocks: int
    # Peers in the swarm (can't use a table because
    #   of: https://forum.nim-lang.org/t/12796)
    peers*: Table[PeerId, SwarmPeerCtx]
    # Local block store for this instance
    localStore*: BlockStore
    # Tracks futures of blockexc tasks
    trackedFutures: TrackedFutures
    # Network interface
    network*: BlockExcNetwork
    discovery*: Discovery

    completionHandle: Future[?!void]

proc `$`(self: SwarmPeerCtx): string =
  return "SwarmPeerCtx(id = " & $self.id & ")"

proc cid(self: Swarm): Cid =
  return self.manifest.treeCid

proc downloadStatus*(self: Swarm): (int, int) =
  return (self.downloadedBlocks, self.manifest.blocksCount)

iterator blockIndices(self: SwarmPeerCtx): int =
  ## Iterates over the indices of blocks that the peer has.
  for i in 0 ..< self.blocks.len:
    if self.blocks[i]:
      yield i

proc isDownloaded(self: Swarm): bool =
  return self.downloadedBlocks == self.manifest.blocksCount

proc updateDownloadedBlocks(self: Swarm, value: int) =
  ## Updates the number of downloaded blocks, completing the download
  ## handle if we're done.
  doAssert self.downloadedBlocks <= value and value <= self.manifest.blocksCount

  self.downloadedBlocks = value
  if self.isDownloaded():
    self.completionHandle.complete(success())

proc addNeighbor(self: Swarm, peer: PeerId) =
  trace "Adding neighbor", peer = peer
  if peer in self.peers:
    warn "Neighbor already exists and will not be added again", peer = peer
    return

  self.peers[peer] = SwarmPeerCtx(
    id: peer, lastRefresh: Moment.now(), blocks: newSeq[bool](self.manifest.blocksCount)
  )

proc resample(self: Swarm) {.async: (raises: [CancelledError]).} =
  var peers = await self.discovery.find(self.manifest.treeCid)
  trace "Found neighbors", count = peers.len

  peers = peers.filterIt(it.data.peerId notin self.peers).toSeq

  let dialed = await allFinished(peers.mapIt(self.network.dialPeer(it.data)))
  for i, f in dialed:
    if f.failed:
      trace "Dial peer failed", peer = peers[i].data.peerId
      await self.discovery.removeProvider(peers[i].data.peerId)
    else:
      if self.peers.len < self.maxNeighbors:
        self.addNeighbor(peers[i].data.peerId)

  trace "Swarm neighbors after resample", count = self.peers.len

proc getStalePeers*(self: Swarm, n: int = DefaultRefreshPeerCount): seq[PeerId] =
  proc cmpStale(x, y: SwarmPeerCtx): int =
    cmp(x.lastRefresh, y.lastRefresh)

  if self.peers.len == 0:
    return @[]

  var peers = self.peers.values().toSeq
  peers.sort(cmpStale)
  return peers[0 .. min(n, peers.len - 1)].mapIt(it.id).toSeq

proc refreshBlockKnowledge(
    self: Swarm, peer: PeerId
): Future[void] {.async: (raises: [CancelledError]).} =
  # Exchanges knowledge on blocks with peering neighbor

  trace "Asking for block knowledge to peer", peer = peer
  try:
    if not self.peers[peer].blockKnowledgeRequest.isNil:
      trace "Pending knowledge update already in progress", peer = peer
      return

    trace "Setup reply future for block knowledge request"

    self.peers[peer].blockKnowledgeRequest = Future[void].Raising([CancelledError]).init(
        "codex.blockexchange.swarm.refreshBlockKnowledge"
      )

    # We abuse the want list message to ask for block knowledge.
    await self.network.request.sendWantList(
      peer,
      addresses = @[init(BlockAddress, self.cid)],
      wantType = WantType.WantHave,
      full = true,
    )

    # Ideally we should only update this once we get a reply, and temporarily
    #  exclude the peer from the refresh loop while it is pending.
    self.peers[peer].lastRefresh = Moment.now()
  except KeyError:
    trace "Cannot refresh update timestamp for dropped peer", peer = peer

proc neighborMaintenanceLoop*(self: Swarm): Future[void] {.async: (raises: []).} =
  try:
    trace "Starting neighbor maintenance loop", cid = self.cid
    while true:
      # Should check/remove dead peers.
      if self.peers.len < self.minNeighbors:
        trace "Too few neighbors, resampling", neighbors = self.peers.len
        # XXX need backoff when you can't get enough neighbors
        await self.resample()

      trace "Resampled, neighbors", neighbors = self.peers.len

      let peers = self.getStalePeers()
      for peer in peers:
        info "Refreshing block knowledge for peer", peer = peer
        await self.refreshBlockKnowledge(peer)

      # We should use separate refresh timers per peer and run this in an
      # event driven fashion.
      await sleepAsync(1.seconds)
  except CancelledError:
    trace "Swarm neighbor maintenance loop cancelled. Exiting."

proc advertiseLoop*(self: Swarm): Future[void] {.async: (raises: []).} =
  try:
    while true:
      trace "Advertising CID", cid = self.cid
      await self.discovery.provide(self.cid)
      trace "Avertiser going to sleep"
      await sleepAsync(DefaultAdvertisementInterval)
  except CancelledError:
    trace "Advertisement loop cancelled. Exiting."

proc loadBlockKnowledge*(self: Swarm): Future[void] {.async: (raises: []).} =
  ## Load block knowledge from local store
  ##

  info "Loading block knowledge for CID", cid = self.cid
  var totalBlocks = 0

  self.blocks.setLen(self.manifest.blocksCount)
  for blockIndex in 0 ..< self.manifest.blocksCount:
    try:
      without hasBlock =? await self.localStore.hasBlock(self.cid, blockIndex), err:
        error "Failed to check block presence", err = err.msg
      if hasBlock:
        self.blocks[blockIndex].completed = true
        totalBlocks += 1
    except CatchableError as err:
      error "Failed to check block presence", err = err.msg

  info "Loaded block knowledge for CID", cid = self.cid, count = totalBlocks

  self.updateDownloadedBlocks(totalBlocks)

proc start*(self: Swarm): Future[void] {.async: (raises: []).} =
  trace "Initialize swarm. Load block knowledge.", cid = self.cid
  await self.loadBlockKnowledge()

  trace "Joining swarm."
  # Bootstraps
  self.trackedFutures.track(self.neighborMaintenanceLoop())
  self.trackedFutures.track(self.advertiseLoop())

proc sendBlockRequests(
    self: Swarm, peer: PeerId, requests: seq[int]
) {.async: (raw: true).} =
  return self.network.sendWantList(
    peer,
    requests.mapIt(init(BlockAddress, self.cid, it)),
    wantType = WantType.WantBlock,
  )

proc fillRequests*(self: Swarm, peer: PeerId) {.async: (raises: [CancelledError]).} =
  ## Selects the blocks to request to a neighboring peer up to a maximum
  ## number of pending requests.

  trace "Fill request schedule for peer", peer = peer

  without peerCtx =? self.peers[peer].catch, err:
    error "Cannot fill request schedule for peer", peer = peer
    return

  var
    requests: seq[int]
    requested: int = 0

  for blockIndex in peerCtx.blockIndices:
    if peerCtx.pendingRequests >= self.maxPendingRequests:
      break

    # Already have the block.
    if self.blocks[blockIndex].completed:
      continue

    # Skip busy blocks.
    if self.blocks[blockIndex].requests > 0:
      continue

    requests.add(blockIndex)
    requested += 1
    self.blocks[blockIndex].requests += 1

    try:
      self.peers[peer].pendingRequests += 1
    except KeyError:
      error "Cannot update pending requests for peer", peer = peer
      return

  trace "New request schedule for peer", peer = peer, count = requested

  if requested == 0:
    trace "Peer has no blocks of interest", peer = peer
    return

  try:
    # Request new blocks immediately.
    await sendBlockRequests(self, peer, requests)
  except CatchableError as err:
    # For now we just give up
    trace "Failed to send block requests to peer", peer = peer, err = err.msg

proc handleBlockDelivery(
    self: Swarm, peer: PeerId, blocksDelivery: seq[BlockDelivery]
) {.async: (raises: []).} =
  trace "Got blocks from peer", peer = peer, count = blocksDelivery.len
  without peerCtx =? self.peers[peer].catch, err:
    error "Cannot receive blocks from unknown peer", peer = peer
    return

  try:
    for blockDelivery in blocksDelivery:
      # Could be a duplicate receive
      if self.blocks[blockDelivery.address.index].completed:
        trace "Duplicate block received",
          blockIndex = blockDelivery.address.index, peer = peer
        continue

      # Stores block and proof. We don't validate as this is just an experiment.
      if err =? (await self.localStore.putBlock(blockDelivery.blk)).errorOption:
        error "Unable to store block", err = err.msg
        continue

      if blockDelivery.address.leaf:
        without proof =? blockDelivery.proof:
          warn "Proof expected for a leaf block delivery"
          continue
        if err =? (
          await self.localStore.putCidAndProof(
            blockDelivery.address.treeCid, blockDelivery.address.index,
            blockDelivery.blk.cid, proof,
          )
        ).errorOption:
          warn "Unable to store proof and cid for a block"
          continue

      trace "Block received", blockIndex = blockDelivery.address.index, peer = peer
      self.blocks[blockDelivery.address.index].completed = true

      try:
        self.peers[peer].pendingRequests -= 1
      except KeyError:
        error "Cannot update pending requests for peer", peer = peer
        return

      self.updateDownloadedBlocks(self.downloadedBlocks + 1)
      if self.isDownloaded():
        info "Download completed", cid = self.cid
        return

    # Got some idle space, push more requests to peer.
    await self.fillRequests(peer)
  except CatchableError as err:
    trace "Error handling block delivery", err = err.msg

proc setupPeer(self: Swarm, peer: PeerId) {.async: (raises: [CancelledError]).} =
  # If this is an outbound connection, we should already have the peer in our
  # neighbor set. If it's an inbound connection, it might be the first time we
  # see this peer.
  trace "Setting up peer", peer = peer

  self.addNeighbor(peer)

  await self.refreshBlockKnowledge(peer)

  # Don't fill the request schedule before we get a
  # reply to the block knowledge request.
  try:
    trace "Await for reply to block knowledge request"
    await self.peers[peer].blockKnowledgeRequest
  except KeyError:
    error "Cannot fill request schedule for unknown peer", peer = peer
    return

  trace "Got initial block knowledge. Setup initial block request schedule", peer = peer

  # Fill initial request schedule to peer.
  await self.fillRequests(peer)

proc handleBlockKnowledgeRequest(self: Swarm, peer: PeerId) {.async: (raises: []).} =
  trace "Handling block knowledge request from peer", peer = peer
  var presenceInfo: seq[BlockPresence]
  for blockIndex in 0 ..< self.manifest.blocksCount:
    if self.blocks[blockIndex].completed:
      presenceInfo.add(
        BlockPresence(
          address: init(BlockAddress, self.cid, blockIndex),
          `type`: BlockPresenceType.Have,
        )
      )

  # XXX This will probably be way too expensive to keep sending, even just
  #   for prototyping
  trace "Have block presences to send", count = presenceInfo.len

  try:
    await self.network.request.sendPresence(peer, presenceInfo)
  except CancelledError:
    trace "Sending of block presences cancelled", peer = peer

proc handleBlockKnowledgeResponse(
    self: Swarm, peer: PeerId, presence: seq[BlockPresence]
) {.async: (raises: []).} =
  try:
    trace "Received block knowledge from peer", peer = peer
    var i = 0
    for blockPresence in presence:
      i += 1
      self.peers[peer].blocks[blockPresence.address.index.int] = true

    trace "Peer has blocks", peer = peer, count = i

    var fut = self.peers[peer].blockKnowledgeRequest
    if fut.isNil:
      error "Invalid state for knowledge update"
      return

    fut.complete()
    self.peers[peer].blockKnowledgeRequest = nil
  except KeyError:
    error "Cannot update block presence for peer", peer = peer
    return

proc handleBlockRequest(
    self: Swarm, peer: PeerId, addresses: seq[BlockAddress]
) {.async: (raises: []).} =
  trace "Got request for blocks from peer", peer = peer, count = addresses.len

  proc localLookup(address: BlockAddress): Future[?!BlockDelivery] {.async.} =
    if address.leaf:
      (await self.localStore.getBlockAndProof(address.treeCid, address.index)).map(
        (blkAndProof: (Block, CodexProof)) =>
          BlockDelivery(
            address: address, blk: blkAndProof[0], proof: blkAndProof[1].some
          )
      )
    else:
      (await self.localStore.getBlock(address)).map(
        (blk: Block) => BlockDelivery(
          address: address, blk: blk, proof: CodexProof.none
        )
      )

  try:
    var
      blocks: seq[BlockDelivery]
      remainingSlots: int = self.maxBlocksPerBatch

    # Sends blocks in batches.
    for address in addresses:
      if remainingSlots == 0:
        trace "Sending batch of blocks to peer", peer = peer, count = blocks.len
        await self.network.request.sendBlocksDelivery(peer, blocks)
        blocks = @[]
        remainingSlots = self.maxBlocksPerBatch

      without aBlock =? (await localLookup(address)), err:
        # XXX This looks harmless but it's not. The receiving peer needs to check
        #   that all requested blocks were sent back, and have a retry policy for
        #   blocks that didn't get there.
        warn "Failed to lookup block", address = address
        continue
      blocks.add(aBlock)
      remainingSlots -= 1

    # Sends trailing batch.
    if blocks.len > 0:
      trace "Sending last batch of blocks to peer", peer = peer, count = blocks.len
      await self.network.request.sendBlocksDelivery(peer, blocks)
  except CatchableError as err:
    error "Failed to send blocks to peer", err = err.msg
    return

proc dropPeer*(self: Swarm, peer: PeerId) {.raises: [].} =
  ## Cleanup disconnected peer
  ##

  trace "Dropping peer", peer

  # drop the peer from the peers table
  self.peers.del(peer)

proc new*(
    T: type Swarm,
    dataset: Manifest,
    localStore: BlockStore,
    network: BlockExcNetwork,
    discovery: Discovery,
): Swarm =
  let self = Swarm(
    manifest: dataset,
    localStore: localStore,
    network: network,
    discovery: discovery,
    minNeighbors: DefaultMinNeighbors,
    maxNeighbors: DefaultMaxNeighbors,
    maxPendingRequests: DefaultMaxPendingRequests,
    maxBlocksPerBatch: DefaultMaxBlocksPerBatch,
    downloadedBlocks: 0,
    trackedFutures: TrackedFutures.new(),
    completionHandle: newFuture[?!void]("codex.blockexchange.swarm.start"),
  )

  proc peerEventHandler(
      peerId: PeerId, event: PeerEvent
  ): Future[void] {.gcsafe, async: (raises: [CancelledError]).} =
    if event.kind == PeerEventKind.Joined:
      await self.setupPeer(peerId)
    else:
      self.dropPeer(peerId)

  proc wantListHandler(peer: PeerId, wantList: WantList) {.async: (raises: []).} =
    if wantList.full:
      await self.handleBlockKnowledgeRequest(peer)
    else:
      await self.handleBlockRequest(peer, wantList.entries.mapIt(it.address).toSeq)

  proc blocksPresenceHandler(
      peer: PeerId, presence: seq[BlockPresence]
  ) {.async: (raises: []).} =
    self.handleBlockKnowledgeResponse(peer, presence)

  proc blocksDeliveryHandler(
      peer: PeerId, blocksDelivery: seq[BlockDelivery]
  ): Future[void] {.async: (raises: []).} =
    self.handleBlockDelivery(peer, blocksDelivery)

  if not isNil(network.switch):
    network.switch.addPeerEventHandler(peerEventHandler, PeerEventKind.Joined)
    network.switch.addPeerEventHandler(peerEventHandler, PeerEventKind.Left)

  network.handlers = BlockExcHandlers(
    onWantList: wantListHandler,
    onBlocksDelivery: blocksDeliveryHandler,
    onPresence: blocksPresenceHandler,
    onAccount: nil,
    onPayment: nil,
  )

  return self
