## Logos Storage
## Copyright (c) 2021 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import std/[sequtils, sets, options, algorithm, sugar, tables]

import pkg/chronos
import pkg/libp2p/[cid, switch, multihash, multicodec]
import pkg/metrics
import pkg/questionable
import pkg/questionable/results
import pkg/stew/shims/sets

import ../../stores/blockstore
import ../../errors
import ../../blocktype
import ../../utils
import ../../utils/trackedfutures
import ../../merkletree
import ../../logutils
import ../protocol/message
import ../protocol/presence
import ../protocol/constants

import ../network
import ../peers
import ../utils as bexutils

import ./discovery
import ./advertiser
import ./downloadmanager
import ./swarm
import ./scheduler

export peers, downloadmanager, discovery, swarm, scheduler

logScope:
  topics = "storage blockexcengine"

declareCounter(
  storage_block_exchange_want_have_lists_received,
  "storage blockexchange wantHave lists received",
)
declareCounter(storage_block_exchange_blocks_sent, "storage blockexchange blocks sent")
declareCounter(
  storage_block_exchange_blocks_received, "storage blockexchange blocks received"
)
declareCounter(
  storage_block_exchange_discovery_requests_total,
  "Total number of peer discovery requests sent",
)
declareCounter(
  storage_block_exchange_peer_timeouts_total, "Total number of peer activity timeouts"
)
declareCounter(
  storage_block_exchange_requests_failed_total,
  "Total number of block requests that failed after exhausting retries",
)

const
  # Don't do more than one discovery request per `DiscoveryRateLimit` seconds.
  DiscoveryRateLimit = 3.seconds

type
  BlockExcEngine* = ref object of RootObj
    localStore*: BlockStore # Local block store for this instance
    network*: BlockExcNetwork
    peers*: PeerContextStore # Peers we're currently actively exchanging with
    trackedFutures: TrackedFutures # Tracks futures of blockexc tasks
    blockexcRunning: bool # Indicates if the blockexc task is running
    downloadManager*: DownloadManager
    discovery*: DiscoveryEngine
    advertiser*: Advertiser
    lastDiscRequest: Moment # Time of last discovery request
    selectionPolicy*: SelectionPolicy # Block selection policy for block scheduling
    activeDownloads*: HashSet[uint64] # Track running download workers by download ID

  DownloadHandleGeneric*[T] = object
    cid*: Cid
    downloadId*: uint64
    iter*: SafeAsyncIter[T]
    completionFuture*: Future[?!void].Raising([CancelledError])

  DownloadHandle* = DownloadHandleGeneric[Block]
  DownloadHandleOpaque* = DownloadHandleGeneric[void]

proc finished*[T](h: DownloadHandleGeneric[T]): bool =
  h.iter.finished

proc next*[T](
    h: DownloadHandleGeneric[T]
): Future[?!T] {.async: (raw: true, raises: [CancelledError]).} =
  h.iter.next()

proc waitForComplete*[T](
    h: DownloadHandleGeneric[T]
): Future[?!void] {.async: (raises: [CancelledError]).} =
  return await h.completionFuture

proc nextBlock*(
    h: DownloadHandle
): Future[?!Block] {.async: (raw: true, raises: [CancelledError]).} =
  h.iter.next()

proc requestWantBlocks*(
  self: BlockExcEngine, peer: PeerId, blockRange: BlockRange
): Future[WantBlocksResult[seq[BlockDeliveryView]]] {.
  async: (raises: [CancelledError])
.}

proc downloadWorker(
  self: BlockExcEngine, download: ActiveDownload
) {.async: (raises: []).}

proc ensureDownloadWorker(
  self: BlockExcEngine, download: ActiveDownload
) {.gcsafe, raises: [].}

proc startDownload(
  self: BlockExcEngine, desc: DownloadDesc
): ActiveDownload {.gcsafe, raises: [].}

proc startDownload(
  self: BlockExcEngine, desc: DownloadDesc, missingBlocks: seq[uint64]
): ActiveDownload {.gcsafe, raises: [].}

proc start*(self: BlockExcEngine) {.async: (raises: []).} =
  ## Start the blockexc task
  ##
  await self.discovery.start()
  await self.advertiser.start()

  if self.blockexcRunning:
    warn "Starting blockexc twice"
    return

  self.blockexcRunning = true

proc stop*(self: BlockExcEngine) {.async: (raises: []).} =
  ## Stop the blockexc
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

proc searchForNewPeers(self: BlockExcEngine, cid: Cid) =
  if self.lastDiscRequest + DiscoveryRateLimit < Moment.now():
    trace "Searching for new peers for", cid = cid
    storage_block_exchange_discovery_requests_total.inc()
    self.lastDiscRequest = Moment.now() # always refresh before calling await
    self.discovery.queueFindBlocksReq(@[cid])
  else:
    trace "Not searching for new peers, rate limit not expired", cid = cid

proc banAndDropPeer(
    self: BlockExcEngine, download: ActiveDownload, cid: Cid, peerId: PeerId
) {.async: (raises: [CancelledError]).} =
  download.ctx.swarm.banPeer(peerId)
  download.handlePeerFailure(peerId)
  if download.ctx.swarm.needsPeers():
    self.searchForNewPeers(cid)
  await self.network.dropPeer(peerId)

proc evictPeer(self: BlockExcEngine, peer: PeerId) =
  ## Cleanup disconnected peer
  ##

  trace "Evicting disconnected/departed peer", peer
  self.peers.remove(peer)

proc validateBlockDeliveryView(self: BlockExcEngine, view: BlockDeliveryView): ?!void =
  without proof =? view.proof:
    return failure("Missing proof")

  if proof.index != view.address.index:
    return failure(
      "Proof index " & $proof.index & " doesn't match leaf index " & $view.address.index
    )

  without expectedMhash =? view.cid.mhash.mapFailure, err:
    return failure("Unable to get mhash from cid for block, nested err: " & err.msg)

  without computedMhash =?
    MultiHash.digest(
      $expectedMhash.mcodec,
      view.sharedBuf.data.toOpenArray(
        view.dataOffset, view.dataOffset + view.dataLen - 1
      ),
    ).mapFailure, err:
    return failure("Unable to compute hash of block data, nested err: " & err.msg)

  if computedMhash != expectedMhash:
    return failure("Block data hash doesn't match claimed CID")

  without treeRoot =? view.address.treeCid.mhash.mapFailure, err:
    return failure("Unable to get mhash from treeCid for block, nested err: " & err.msg)

  if err =? proof.verify(computedMhash, treeRoot).errorOption:
    return failure("Unable to verify proof for block, nested err: " & err.msg)

  return success()

proc sendWantBlocksRequest(
    self: BlockExcEngine,
    download: ActiveDownload,
    start: uint64,
    count: uint64,
    peer: PeerContext,
): Future[void] {.async: (raises: [CancelledError]).} =
  if download.cancelled:
    return

  let cid = download.cid
  var
    missingIndices: seq[uint64] = @[]
    localBlockCount: uint64 = 0

  for i in start ..< start + count:
    let address = download.makeBlockAddress(i)

    if download.isBlockExhausted(address):
      continue

    let exists =
      try:
        await address in self.localStore
      except CatchableError as e:
        warn "Error checking block existence", address = address, error = e.msg
        false

    if not exists:
      missingIndices.add(i)
    else:
      localBlockCount += 1
      # try to complete handle if iterator is still waiting
      if address in download.blocks:
        let blkResult = await self.localStore.getBlock(address)
        if blkResult.isOk:
          discard download.completeWantHandle(address, some(blkResult.get))

  download.markBatchInFlight(start, count, localBlockCount, peer.id)

  if missingIndices.len == 0:
    # all blocks were local
    download.completeBatch(start, 0, 0)
    return

  var ranges: seq[tuple[start: uint64, count: uint64]] = @[]
  if missingIndices.len > 0:
    var
      rangeStart = missingIndices[0]
      rangeCount: uint64 = 1

    for i in 1 ..< missingIndices.len:
      if missingIndices[i] == rangeStart + rangeCount:
        rangeCount += 1
      else:
        ranges.add((rangeStart, rangeCount))
        rangeStart = missingIndices[i]
        rangeCount = 1

    ranges.add((rangeStart, rangeCount))

  trace "Requesting missing blocks",
    cid = cid,
    originalRange = $(start, count),
    missing = missingIndices.len,
    ranges = ranges.len,
    peer = peer.id

  let
    requestStartTime = Moment.now()
    requestResult =
      await self.requestWantBlocks(peer.id, BlockRange(cid: cid, ranges: ranges))
    rttMicros = (Moment.now() - requestStartTime).microseconds.uint64

  if download.cancelled:
    return

  # request might have timed-out and have been requeued to another peer
  # if yes, then discard response, it's already handled.
  download.pendingBatches.withValue(start, pending):
    if pending[].peerId != peer.id:
      # discard it, was reassigned
      return
  do:
    # either completed or requeued
    return

  if requestResult.isErr:
    warn "Batch request failed", peer = peer.id, error = requestResult.error.msg
    let swarm = download.ctx.swarm
    if swarm.recordPeerFailure(peer.id):
      warn "Peer exceeded max failures, removing from swarm", peer = peer.id
      if swarm.removePeer(peer.id).isNone:
        trace "Peer was not in swarm", peer = peer.id

      download.handlePeerFailure(peer.id)

      if swarm.needsPeers():
        self.searchForNewPeers(cid)
    else:
      # we can requeue immediately (cancels timeout), no benefit waiting for timeout.
      download.requeueBatch(start, count, front = true)
    return

  let allBlockViews = requestResult.get

  if allBlockViews.len == 0:
    trace "Peer responded with zero blocks", peer = peer.id, cid = cid
    download.requeueBatch(start, count, front = false)
    return

  trace "Received batch response",
    cid = cid,
    originalRange = $(start, count),
    received = allBlockViews.len,
    requested = missingIndices.len,
    peer = peer.id

  var
    totalBytes: uint64 = 0
    validCount: int = 0
    receivedIndices: HashSet[uint64]

  for view in allBlockViews:
    if not bexutils.isIndexInRanges(
      view.address.index.uint64, ranges, sortedRanges = true
    ):
      warn "Received unrequested block", index = view.address.index, ranges = ranges.len
      continue

    if view.address.index.uint64 >= download.ctx.totalBlocks:
      warn "Received block with out-of-bounds index - banning peer",
        index = view.address.index,
        totalBlocks = download.ctx.totalBlocks,
        peer = peer.id
      await self.banAndDropPeer(download, cid, peer.id)
      return

    if err =? self.validateBlockDeliveryView(view).errorOption:
      error "Block validation failed - corrupted data from peer",
        address = view.address, msg = err.msg, peer = peer.id
      warn "Banning peer for sending corrupted block data", peer = peer.id
      await self.banAndDropPeer(download, cid, peer.id)
      return

    let
      bd = view.toBlockDelivery()
      putResult = await self.localStore.putBlock(bd.blk)
    if putResult.isErr:
      warn "Failed to store block", address = bd.address, error = putResult.error.msg
      continue

    let proofResult = await self.localStore.putCidAndProof(
      bd.address.treeCid, bd.address.index, bd.blk.cid, bd.proof.get
    )
    if proofResult.isErr:
      warn "Failed to store proof", address = bd.address
      discard await self.localStore.delBlock(bd.blk.cid)
      continue

    totalBytes += bd.blk.data[].len.uint64
    validCount += 1
    receivedIndices.incl(bd.address.index.uint64)

    if bd.address in download.blocks:
      discard download.completeWantHandle(bd.address, some(bd.blk))

  storage_block_exchange_blocks_received.inc(validCount.int64)

  download.ctx.swarm.recordBatchSuccess(peer, rttMicros, totalBytes)

  if validCount < missingIndices.len:
    trace "Peer delivered partial batch, computing missing ranges",
      peer = peer.id, requested = missingIndices.len, received = validCount

    var stillMissing: seq[uint64]
    for idx in missingIndices:
      if idx notin receivedIndices:
        stillMissing.add(idx)

    if stillMissing.len > 0:
      var penaltyAddresses: seq[BlockAddress]
      let peerAvail = download.ctx.swarm.getPeer(peer.id)
      for idx in stillMissing:
        if peerAvail.isSome and peerAvail.get().availability.hasRange(idx, 1):
          penaltyAddresses.add(download.makeBlockAddress(idx))

      let exhausted = download.decrementBlockRetries(penaltyAddresses)
      if exhausted.len > 0:
        warn "Blocks exhausted retries after partial delivery",
          cid = cid, exhaustedCount = exhausted.len
        download.failExhaustedBlocks(exhausted)
        let exhaustedIndices = exhausted.mapIt(it.index.uint64).toHashSet
        stillMissing = stillMissing.filterIt(it notin exhaustedIndices)

    var missingRanges: seq[tuple[start: uint64, count: uint64]] = @[]
    if stillMissing.len > 0:
      stillMissing.sort()
      var
        rangeStart = stillMissing[0]
        rangeCount: uint64 = 1

      for i in 1 ..< stillMissing.len:
        if stillMissing[i] == rangeStart + rangeCount:
          rangeCount += 1
        else:
          missingRanges.add((rangeStart, rangeCount))
          rangeStart = stillMissing[i]
          rangeCount = 1

      missingRanges.add((rangeStart, rangeCount))

    trace "Partial batch completion - requeuing missing ranges",
      cid = cid,
      originalStart = start,
      originalCount = count,
      received = validCount,
      missingRanges = missingRanges.len

    download.partialCompleteBatch(
      start, count, validCount.uint64, missingRanges, totalBytes
    )
  else:
    download.completeBatch(start, validCount.uint64, totalBytes)

proc ensureDownloadWorker(
    self: BlockExcEngine, download: ActiveDownload
) {.gcsafe, raises: [].} =
  let id = download.id
  if id in self.activeDownloads:
    return

  self.activeDownloads.incl(id)

  proc wrappedDownloadWorker() {.async: (raises: []).} =
    try:
      await self.downloadWorker(download)
    finally:
      self.activeDownloads.excl(id)

  self.trackedFutures.track(wrappedDownloadWorker())

proc startDownload(
    self: BlockExcEngine, desc: DownloadDesc
): ActiveDownload {.gcsafe, raises: [].} =
  result = self.downloadManager.startDownload(desc)
  self.ensureDownloadWorker(result)

proc startDownload(
    self: BlockExcEngine, desc: DownloadDesc, missingBlocks: seq[uint64]
): ActiveDownload {.gcsafe, raises: [].} =
  result = self.downloadManager.startDownload(desc, missingBlocks)
  self.ensureDownloadWorker(result)

proc broadcastWantHave(
    self: BlockExcEngine,
    download: ActiveDownload,
    cid: Cid,
    start: uint64,
    count: uint64,
    peers: seq[PeerContext],
) {.async: (raises: [CancelledError]).} =
  let rangeAddress = BlockAddress.init(cid, start.int)
  for peerCtx in peers:
    if not download.addPeerIfAbsent(peerCtx.id, BlockAvailability.unknown()):
      # skip presence request for peer with Complete availability
      continue

    try:
      await self.network.request
        .sendWantList(
          peerCtx.id,
          @[rangeAddress],
          priority = 0,
          cancel = false,
          wantType = WantType.WantHave,
          full = false,
          sendDontHave = false,
          rangeCount = count,
          downloadId = download.id,
        )
        .wait(DefaultWantHaveSendTimeout)
    except AsyncTimeoutError:
      warn "Want-have send timed out", peer = peerCtx.id
    except CatchableError as err:
      warn "Want-have send failed", peer = peerCtx.id, error = err.msg

proc handleBatchRetry(
    self: BlockExcEngine,
    download: ActiveDownload,
    cid: Cid,
    start: uint64,
    count: uint64,
    waitTime: Duration,
) {.async: (raises: [CancelledError]).} =
  # we decrement retries, fail exhausted blocks, requeue, and wait.
  let
    addresses = download.getBlockAddressesForRange(start, count)
    exhausted = download.decrementBlockRetries(addresses)
  if exhausted.len > 0:
    warn "Block retries exhausted", cid = cid, exhaustedCount = exhausted.len
    download.failExhaustedBlocks(exhausted)

  download.requeueBatch(start, count, front = false)
  await sleepAsync(waitTime)

proc downloadWorker(
    self: BlockExcEngine, download: ActiveDownload
) {.async: (raises: []).} =
  ## Continuously schedules batches to peers until download completes.
  ## Supports concurrent batch requests per peer based on BDP pipeline depth.
  ## When block size is unknown (0), BDP optimizations are disabled - first batch
  ## is used to discover block size, then BDP calculations start.
  let
    cid = download.cid
    retryInterval = self.downloadManager.retryInterval
  logScope:
    cid = cid

  try:
    let
      (windowStart, windowCount) = download.ctx.currentPresenceWindow()
      connectedPeers = self.peers.toSeq()

    if connectedPeers.len > 0:
      trace "Initial presence window broadcast",
        cid = cid,
        windowStart = windowStart,
        windowCount = windowCount,
        totalBlocks = download.ctx.totalBlocks

      await self.broadcastWantHave(
        download, cid, windowStart, windowCount, connectedPeers
      )
      trace "Initial broadcast sent, proceeding to batch loop"
    else:
      trace "No connected peers for initial broadcast, triggering discovery"
      self.searchForNewPeers(cid)

    while not download.cancelled and not download.isDownloadComplete():
      for peerId in download.inFlightBatches.keys.toSeq:
        var remaining: seq[Future[void]] = @[]
        for fut in download.inFlightBatches[peerId]:
          if not fut.finished:
            remaining.add(fut)
        if remaining.len > 0:
          download.inFlightBatches[peerId] = remaining
        else:
          download.inFlightBatches.del(peerId)

      let ctx = download.ctx
      if not download.fetchLocal and ctx.needsNextPresenceWindow():
        let (newStart, newCount) = ctx.advancePresenceWindow()

        ctx.trimPresenceBeforeWatermark()

        # Broadcast want-have for the new window
        let connectedPeers = self.peers.toSeq()

        trace "Advancing presence window",
          cid = cid,
          newWindowStart = newStart,
          newWindowCount = newCount,
          watermark = ctx.scheduler.completedWatermark()

        await self.broadcastWantHave(download, cid, newStart, newCount, connectedPeers)

      # Broadcast availability to peers
      if not download.fetchLocal and ctx.shouldBroadcastAvailability():
        let broadcastRanges = ctx.getAvailabilityBroadcast()
        if broadcastRanges.len > 0:
          trace "Broadcasting availability to swarm",
            cid = cid,
            rangeCount = broadcastRanges.len,
            swarmPeers = ctx.swarm.peerCount()

          let presence = BlockPresence(
            address: BlockAddress(treeCid: cid, index: broadcastRanges[0].start.int),
            kind: BlockPresenceType.HaveRange,
            ranges: broadcastRanges,
          )

          for peerId in ctx.swarm.connectedPeers():
            let peerOpt = ctx.swarm.getPeer(peerId)
            if peerOpt.isSome and peerOpt.get().availability.kind == bakComplete:
              continue

            try:
              await self.network.request.sendPresence(peerId, @[presence]).wait(
                DefaultWantHaveSendTimeout
              )
            except AsyncTimeoutError:
              trace "Availability broadcast send timed out", peer = peerId
            except CatchableError as err:
              trace "Failed to broadcast availability", peer = peerId, error = err.msg

          ctx.markAvailabilityBroadcasted()

      let batchOpt = self.downloadManager.getNextBatch(download)
      if batchOpt.isNone:
        let pendingBatchCount = download.pendingBatchCount()

        if pendingBatchCount == 0:
          break

        await sleepAsync(100.milliseconds)
        continue

      let (start, count) = batchOpt.get()
      logScope:
        batchStart = start
        batchCount = count

      block localCheck:
        for i in start ..< start + count:
          let address = download.makeBlockAddress(i)
          if download.isBlockExhausted(address):
            break localCheck
          let exists =
            try:
              await address in self.localStore
            except CatchableError:
              false
          if not exists:
            if download.fetchLocal:
              download.failLocalMissing(address)
              break localCheck
            break localCheck

        for i in start ..< start + count:
          let address = download.makeBlockAddress(i)
          if address in download.blocks:
            without blk =? (await self.localStore.getBlock(address)), err:
              break localCheck
            discard download.completeWantHandle(address, some(blk))

        download.completeBatchLocal(start, count)
        continue

      if download.cancelled or download.fetchLocal:
        continue

      let swarm = download.ctx.swarm
      var shouldBroadcast = false

      let peersNeeded = swarm.peersNeeded()
      if peersNeeded > 0:
        trace "Swarm below target, triggering discovery",
          active = swarm.activePeerCount(), needed = peersNeeded
        self.searchForNewPeers(cid)

      if swarm.peersWithRange(start, count).len == 0:
        shouldBroadcast = true

      if shouldBroadcast:
        let connectedPeers = self.peers.toSeq()

        if connectedPeers.len > 0:
          trace "Broadcasting want-have for batch range",
            cid = cid, start = start, count = count, peerCount = connectedPeers.len

          await self.broadcastWantHave(download, cid, start, count, connectedPeers)
          # Give peers a short time to respond with presence
          await sleepAsync(50.milliseconds)
        else:
          trace "No connected peers, searching for new peers"
          self.searchForNewPeers(cid)
          await self.handleBatchRetry(download, cid, start, count, retryInterval)
          continue

      if self.peers.len == 0:
        trace "No connected peers available for batch, searching"
        self.searchForNewPeers(cid)
        await self.handleBatchRetry(download, cid, start, count, 100.milliseconds)
        continue

      let staleUnknown = swarm.staleUnknownPeers()
      if staleUnknown.len > 0:
        let rangeAddress = download.makeBlockAddress(start)

        trace "Re-querying stale unknown peers",
          cid = cid,
          staleUnknownCount = staleUnknown.len,
          batchStart = start,
          batchCount = count

        for peerId in staleUnknown:
          try:
            await self.network.request
              .sendWantList(
                peerId,
                @[rangeAddress],
                priority = 0,
                cancel = false,
                wantType = WantType.WantHave,
                full = false,
                sendDontHave = false,
                rangeCount = count,
                downloadId = download.id,
              )
              .wait(DefaultWantHaveSendTimeout)
          except AsyncTimeoutError:
            trace "Re-query stale unknown peer send timed out", peer = peerId
          except CatchableError as err:
            trace "Failed to re-query stale unknown peer",
              peer = peerId, error = err.msg

        await sleepAsync(50.milliseconds)

      let
        batchBytes = download.ctx.batchBytes
        selection = swarm.selectPeerForBatch(
          self.peers, start, count, batchBytes, download.inFlightBatches
        )

      if selection.kind == pskNoPeers:
        trace "No peer with range, searching for new peers"
        let
          hasActivePeers = swarm.activePeerCount() > 0
          waitTime = if hasActivePeers: retryInterval else: 100.milliseconds
        await self.handleBatchRetry(download, cid, start, count, waitTime)
        continue

      if selection.kind == pskAtCapacity:
        download.requeueBatch(start, count, front = false)
        await sleepAsync(10.milliseconds)
        continue

      let
        peer = selection.peer
        batchFuture = self.sendWantBlocksRequest(download, start, count, peer)

      if peer.id notin download.inFlightBatches:
        download.inFlightBatches[peer.id] = @[]
      download.inFlightBatches[peer.id].add(batchFuture)

      download.setBatchRequestFuture(start, batchFuture)

      let timeout = download.ctx.batchTimeout(peer, count)
      proc batchTimeoutHandler(dl: ActiveDownload) {.async: (raises: []).} =
        try:
          await sleepAsync(timeout)
        except CancelledError:
          return

        if dl.cancelled:
          return

        dl.pendingBatches.withValue(start, pending):
          if pending[].peerId == peer.id:
            trace "Batch timed out", peer = peer.id, start = start, count = count
            storage_block_exchange_peer_timeouts_total.inc()

            let swarm = dl.ctx.swarm
            if swarm.recordPeerTimeout(peer.id):
              warn "Peer exceeded max timeouts, removing from swarm", peer = peer.id
              discard swarm.removePeer(peer.id)

            let
              addresses = dl.getBlockAddressesForRange(start, count)
              exhausted = dl.decrementBlockRetries(addresses)

            if exhausted.len > 0:
              warn "Blocks exhausted retries after timeout",
                cid = cid, exhaustedCount = exhausted.len
              dl.failExhaustedBlocks(exhausted)

            dl.requeueBatch(start, count, front = true)

            if not pending[].requestFuture.isNil and not pending[].requestFuture.finished:
              pending[].requestFuture.cancelSoon()

      let timeoutFut = batchTimeoutHandler(download)
      self.trackedFutures.track(timeoutFut)
      download.setBatchTimeoutFuture(start, timeoutFut)

      await sleepAsync(10.milliseconds)
  except CancelledError:
    trace "Batch download loop cancelled"
  except CatchableError as exc:
    error "Error in batch download loop", err = exc.msg

proc startTreeDownloadGeneric[T: Block | void](
    self: BlockExcEngine,
    treeCid: Cid,
    blockSize: uint32,
    totalBlocks: uint64,
    selectionPolicy: SelectionPolicy = spSequential,
    isBackground: bool = false,
    fetchLocal: bool = false,
): ?!DownloadHandleGeneric[T] =
  ## - T = Block: Returns actual block data (for streaming)
  ## - T = void: Returns success/failure only (for prefetching)

  let
    desc = toDownloadDesc(
      treeCid,
      totalBlocks,
      blockSize,
      selectionPolicy = selectionPolicy,
      isBackground = isBackground,
      fetchLocal = fetchLocal,
    )
    activeDownload = self.startDownload(desc)

  when T is Block:
    trace "Started tree block download", treeCid = treeCid, totalBlocks = totalBlocks

  when T is void:
    type HandleT = BlockHandleOpaque
  else:
    type HandleT = BlockHandle

  var
    pendingHandle: Option[HandleT] = none(HandleT)
    nextBlockToRequest: uint64 = 0

  proc isFinished(): bool =
    nextBlockToRequest >= totalBlocks and pendingHandle.isNone

  proc genNext(): Future[?!T] {.async: (raises: [CancelledError]).} =
    while pendingHandle.isNone and nextBlockToRequest < totalBlocks:
      let address = BlockAddress(treeCid: treeCid, index: nextBlockToRequest.int)
      nextBlockToRequest += 1

      let handle =
        when T is void:
          activeDownload.getWantHandleOpaque(address)
        else:
          activeDownload.getWantHandle(address)

      when T is void:
        let exists =
          try:
            await address in self.localStore
          except CatchableError:
            false
        if exists:
          discard activeDownload.completeWantHandle(address)
        elif fetchLocal:
          handle.cancel()
          return failure(
            newException(BlockNotFoundError, "Block not found locally: " & $address)
          )
      else:
        let blkResult = await self.localStore.getBlock(address)
        if blkResult.isOk:
          discard activeDownload.completeWantHandle(address, some(blkResult.get))
        elif not (blkResult.error of BlockNotFoundError) or fetchLocal:
          handle.cancel()
          return failure(blkResult.error)

      pendingHandle = some(handle)

    if pendingHandle.isNone:
      return failure("No more blocks")

    let handle = pendingHandle.get()
    pendingHandle = none(HandleT)
    let blkResult = await handle
    if blkResult.isOk:
      activeDownload.markBlockReturned()
    return blkResult

  success DownloadHandleGeneric[T](
    cid: treeCid,
    downloadId: activeDownload.id,
    iter: SafeAsyncIter[T].new(genNext, isFinished),
    completionFuture: activeDownload.completionFuture,
  )

proc startTreeDownload*(
    self: BlockExcEngine,
    treeCid: Cid,
    blockSize: uint32,
    totalBlocks: uint64,
    fetchLocal: bool = false,
): ?!DownloadHandle =
  startTreeDownloadGeneric[Block](
    self, treeCid, blockSize, totalBlocks, fetchLocal = fetchLocal
  )

proc startTreeDownloadOpaque*(
    self: BlockExcEngine,
    treeCid: Cid,
    blockSize: uint32,
    totalBlocks: uint64,
    selectionPolicy: SelectionPolicy = spSequential,
    isBackground: bool = false,
    fetchLocal: bool = false,
): ?!DownloadHandleOpaque =
  startTreeDownloadGeneric[void](
    self,
    treeCid,
    blockSize,
    totalBlocks,
    selectionPolicy = selectionPolicy,
    isBackground = isBackground,
    fetchLocal = fetchLocal,
  )

proc releaseDownload*[T](self: BlockExcEngine, handle: DownloadHandleGeneric[T]) =
  self.downloadManager.releaseDownload(handle.downloadId, handle.cid)

proc cancelDownload*(self: BlockExcEngine, cid: Cid) =
  self.downloadManager.cancelDownload(cid)

proc cancelBackgroundDownload*(
    self: BlockExcEngine, downloadId: uint64, cid: Cid
): bool =
  self.downloadManager.cancelBackgroundDownload(downloadId, cid)

proc getDownloadProgress*(
    self: BlockExcEngine, downloadId: uint64, cid: Cid
): Option[DownloadProgress] =
  self.downloadManager.getDownloadProgress(downloadId, cid)

proc blockPresenceHandler*(
    self: BlockExcEngine, peer: PeerId, blocks: seq[BlockPresence]
) {.async: (raises: []).} =
  trace "Received block presence from peer", peer, len = blocks.len
  let peerCtx = self.peers.get(peer)
  if peerCtx.isNil:
    return

  for blk in blocks:
    if presence =? Presence.init(blk):
      if presence.have:
        let cid = presence.address.treeCid

        let downloadOpt = self.downloadManager.getDownload(blk.downloadId, cid)
        if downloadOpt.isSome:
          let availability =
            case presence.presenceType
            of BlockPresenceType.Complete:
              BlockAvailability.complete()
            of BlockPresenceType.HaveRange:
              if presence.ranges.len > 0:
                BlockAvailability.fromRanges(presence.ranges)
              else:
                BlockAvailability.unknown()
            of BlockPresenceType.DontHave:
              BlockAvailability.unknown()

          downloadOpt.get().updatePeerAvailability(peer, availability)

          # try to propagate peer availability to other downloads for the same CID
          self.downloadManager.downloads.withValue(cid, innerTable):
            for otherId, otherDownload in innerTable[]:
              if otherId != blk.downloadId:
                otherDownload.updatePeerAvailability(peer, availability)

proc wantListHandler*(
    self: BlockExcEngine, peer: PeerId, wantList: WantList
) {.async: (raises: []).} =
  trace "Received want list from peer", peer, entries = wantList.entries.len

  let peerCtx = self.peers.get(peer)
  if peerCtx.isNil:
    return

  var presence: seq[BlockPresence]

  try:
    for e in wantList.entries:
      storage_block_exchange_want_have_lists_received.inc()

      if e.rangeCount > 0:
        let
          startIdx = e.address.index.uint64
          count = e.rangeCount
          treeCid = e.address.treeCid

        if count > MaxPresenceWindowBlocks:
          warn "Rejecting oversized range query",
            peer = peer, treeCid = treeCid, count = count, max = MaxPresenceWindowBlocks
          continue

        trace "Processing range query",
          treeCid = treeCid, start = startIdx, count = count

        var
          ranges: seq[tuple[start: uint64, count: uint64]] = @[]
          rangeStart: uint64 = 0
          inRange = false

        for i in 0'u64 ..< count:
          let address = BlockAddress(treeCid: treeCid, index: (startIdx + i).int)
          let have =
            try:
              await address in self.localStore
            except CatchableError:
              false

          if have:
            if not inRange:
              rangeStart = startIdx + i
              inRange = true
          else:
            if inRange:
              ranges.add((rangeStart, (startIdx + i) - rangeStart))
              inRange = false

        if inRange:
          ranges.add((rangeStart, (startIdx + count) - rangeStart))

        if ranges.len > 0:
          trace "Have blocks in range", treeCid = treeCid, ranges = ranges
          presence.add(
            BlockPresence(
              address: e.address,
              kind: BlockPresenceType.HaveRange,
              ranges: ranges,
              downloadId: e.downloadId,
            )
          )
        else:
          trace "Don't have range", treeCid = treeCid, start = startIdx, count = count
          if e.sendDontHave:
            presence.add(
              BlockPresence(
                address: e.address,
                kind: BlockPresenceType.DontHave,
                downloadId: e.downloadId,
              )
            )
      else:
        let have =
          try:
            await e.address in self.localStore
          except CatchableError:
            false

        if have:
          presence.add(
            BlockPresence(
              address: e.address,
              kind: BlockPresenceType.HaveRange,
              ranges: @[(e.address.index.uint64, 1'u64)],
              downloadId: e.downloadId,
            )
          )
        elif e.sendDontHave:
          presence.add(
            BlockPresence(
              address: e.address,
              kind: BlockPresenceType.DontHave,
              downloadId: e.downloadId,
            )
          )

    if presence.len > 0:
      trace "Sending presence to remote", items = presence.len
      try:
        await self.network.request.sendPresence(peer, presence).wait(
          DefaultWantHaveSendTimeout
        )
      except AsyncTimeoutError:
        warn "Presence response send timed out", peer = peer
  except CancelledError as exc:
    warn "Want list handling cancelled", error = exc.msg

proc peerAddedHandler*(
    self: BlockExcEngine, peer: PeerId
) {.async: (raises: [CancelledError]).} =
  ## Perform initial setup, such as want
  ## list exchange
  ##

  trace "Setting up peer", peer
  if peer notin self.peers:
    let peerCtx = PeerContext.new(peer)
    self.peers.add(peerCtx)

proc localLookup(
    self: BlockExcEngine, address: BlockAddress
): Future[?!BlockDelivery] {.async: (raises: [CancelledError]).} =
  (await self.localStore.getBlockAndProof(address.treeCid, address.index)).map(
    (blkAndProof: (Block, StorageMerkleProof)) =>
      BlockDelivery(address: address, blk: blkAndProof[0], proof: blkAndProof[1].some)
  )

proc requestWantBlocks*(
    self: BlockExcEngine, peer: PeerId, blockRange: BlockRange
): Future[WantBlocksResult[seq[BlockDeliveryView]]] {.
    async: (raises: [CancelledError])
.} =
  let response = ?await self.network.sendWantBlocksRequest(peer, blockRange)
  var blockViews: seq[BlockDeliveryView]

  for btBlock in response.blocks:
    let viewResult =
      toBlockDeliveryView(btBlock, response.treeCid, response.sharedBuffer)
    if viewResult.isOk:
      blockViews.add(viewResult.get)
    else:
      warn "Failed to convert block entry to view", error = viewResult.error.msg

  if blockViews.len == 0:
    trace "Request succeeded but received zero blocks",
      peer = peer,
      cid = blockRange.cid,
      rangeCount = blockRange.ranges.len,
      responseBlockCount = response.blocks.len

  return ok(blockViews)

proc new*(
    T: type BlockExcEngine,
    localStore: BlockStore,
    network: BlockExcNetwork,
    discovery: DiscoveryEngine,
    advertiser: Advertiser,
    peerStore: PeerContextStore,
    downloadManager: DownloadManager,
    selectionPolicy = spSequential,
): BlockExcEngine =
  ## Create new block exchange engine instance
  ##

  let self = BlockExcEngine(
    localStore: localStore,
    peers: peerStore,
    downloadManager: downloadManager,
    network: network,
    trackedFutures: TrackedFutures(),
    discovery: discovery,
    advertiser: advertiser,
    selectionPolicy: selectionPolicy,
    activeDownloads: initHashSet[uint64](),
  )

  proc blockWantListHandler(
      peer: PeerId, wantList: WantList
  ): Future[void] {.async: (raises: []).} =
    self.wantListHandler(peer, wantList)

  proc blockPresenceHandler(
      peer: PeerId, presence: seq[BlockPresence]
  ): Future[void] {.async: (raises: []).} =
    self.blockPresenceHandler(peer, presence)

  proc peerAddedHandler(
      peer: PeerId
  ): Future[void] {.async: (raises: [CancelledError]).} =
    await self.peerAddedHandler(peer)

  proc peerDepartedHandler(
      peer: PeerId
  ): Future[void] {.async: (raises: [CancelledError]).} =
    self.evictPeer(peer)

  proc wantBlocksRequestHandler(
      peer: PeerId, req: WantBlocksRequest
  ): Future[seq[BlockDelivery]] {.async: (raises: [CancelledError]).} =
    var
      blockDeliveries: seq[BlockDelivery]
      notFoundCount = 0
      totalRequested: uint64 = 0

    for (start, count) in req.ranges:
      totalRequested += count
      for i in start ..< start + count:
        let address = BlockAddress(treeCid: req.cid, index: i.Natural)

        let res = await self.localLookup(address)
        if res.isOk:
          blockDeliveries.add(res.get)
        else:
          notFoundCount += 1

    if notFoundCount > 0:
      warn "Some blocks not found in WantBlocks request",
        peer = peer,
        cid = req.cid,
        requested = totalRequested,
        found = blockDeliveries.len,
        notFound = notFoundCount

    storage_block_exchange_blocks_sent.inc(blockDeliveries.len.int64)
    return blockDeliveries

  network.handlers = BlockExcHandlers(
    onWantList: blockWantListHandler,
    onPresence: blockPresenceHandler,
    onWantBlocksRequest: wantBlocksRequestHandler,
    onPeerJoined: peerAddedHandler,
    onPeerDeparted: peerDepartedHandler,
  )

  return self
