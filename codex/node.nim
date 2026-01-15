## Logos Storage
## Copyright (c) 2021 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

{.push raises: [].}

import std/options
import std/sequtils
import std/strformat
import std/sugar
import times

import pkg/taskpools
import pkg/questionable
import pkg/questionable/results
import pkg/chronos

import pkg/libp2p/[switch, multicodec, multihash]
import pkg/libp2p/stream/bufferstream

# TODO: remove once exported by libp2p
import pkg/libp2p/routing_record
import pkg/libp2p/signed_envelope

import ./chunker
import ./clock
import ./blocktype as bt
import ./manifest
import ./merkletree
import ./stores
import ./blockexchange
import ./streams
import ./discovery
import ./utils
import ./errors
import ./logutils
import ./utils/safeasynciter
import ./utils/trackedfutures

export logutils

logScope:
  topics = "codex node"

const
  DefaultFetchBatch = 1024
  MaxOnBatchBlocks = 128
  BatchRefillThreshold = 0.75 # Refill when 75% of window completes

type
  CodexNode* = object
    switch: Switch
    networkId: PeerId
    networkStore: NetworkStore
    engine: BlockExcEngine
    discovery: Discovery
    clock*: Clock
    taskPool: Taskpool
    trackedFutures: TrackedFutures

  CodexNodeRef* = ref CodexNode

  OnManifest* = proc(cid: Cid, manifest: Manifest): void {.gcsafe, raises: [].}
  BatchProc* =
    proc(blocks: seq[bt.Block]): Future[?!void] {.async: (raises: [CancelledError]).}
  OnBlockStoredProc = proc(chunk: seq[byte]): void {.gcsafe, raises: [].}

func switch*(self: CodexNodeRef): Switch =
  return self.switch

func blockStore*(self: CodexNodeRef): BlockStore =
  return self.networkStore

func engine*(self: CodexNodeRef): BlockExcEngine =
  return self.engine

func discovery*(self: CodexNodeRef): Discovery =
  return self.discovery

proc storeManifest*(
    self: CodexNodeRef, manifest: Manifest
): Future[?!bt.Block] {.async.} =
  without encodedVerifiable =? manifest.encode(), err:
    trace "Unable to encode manifest"
    return failure(err)

  without blk =? bt.Block.new(data = encodedVerifiable, codec = ManifestCodec), error:
    trace "Unable to create block from manifest"
    return failure(error)

  if err =? (await self.networkStore.putBlock(blk)).errorOption:
    trace "Unable to store manifest block", cid = blk.cid, err = err.msg
    return failure(err)

  success blk

proc fetchManifest*(
    self: CodexNodeRef, cid: Cid
): Future[?!Manifest] {.async: (raises: [CancelledError]).} =
  ## Fetch and decode a manifest block
  ##

  if err =? cid.isManifest.errorOption:
    return failure "CID has invalid content type for manifest {$cid}"

  trace "Retrieving manifest for cid", cid

  without blk =? await self.networkStore.getBlock(BlockAddress.init(cid)), err:
    trace "Error retrieve manifest block", cid, err = err.msg
    return failure err

  trace "Decoding manifest for cid", cid

  without manifest =? Manifest.decode(blk), err:
    trace "Unable to decode as manifest", err = err.msg
    return failure("Unable to decode as manifest")

  trace "Decoded manifest", cid

  return manifest.success

proc findPeer*(self: CodexNodeRef, peerId: PeerId): Future[?PeerRecord] {.async.} =
  ## Find peer using the discovery service from the given CodexNode
  ##
  return await self.discovery.findPeer(peerId)

proc connect*(
    self: CodexNodeRef, peerId: PeerId, addrs: seq[MultiAddress]
): Future[void] =
  self.switch.connect(peerId, addrs)

proc updateExpiry*(
    self: CodexNodeRef, manifestCid: Cid, expiry: SecondsSince1970
): Future[?!void] {.async: (raises: [CancelledError]).} =
  without manifest =? await self.fetchManifest(manifestCid), error:
    trace "Unable to fetch manifest for cid", manifestCid
    return failure(error)

  try:
    let ensuringFutures = Iter[int].new(0 ..< manifest.blocksCount).mapIt(
        self.networkStore.localStore.ensureExpiry(manifest.treeCid, it, expiry)
      )

    let res = await allFinishedFailed[?!void](ensuringFutures)
    if res.failure.len > 0:
      trace "Some blocks failed to update expiry", len = res.failure.len
      return failure("Some blocks failed to update expiry (" & $res.failure.len & " )")
  except CancelledError as exc:
    raise exc
  except CatchableError as exc:
    return failure(exc.msg)

  return success()

proc fetchBatched*(
    self: CodexNodeRef,
    cid: Cid,
    iter: Iter[int],
    batchSize = DefaultFetchBatch,
    onBatch: BatchProc = nil,
    fetchLocal = true,
): Future[?!void] {.async: (raises: [CancelledError]), gcsafe.} =
  ## Fetch blocks in batches of `batchSize`
  ##

  # TODO: doesn't work if callee is annotated with async
  # let
  #   iter = iter.map(
  #     (i: int) => self.networkStore.getBlock(BlockAddress.init(cid, i))
  #   )

  # Sliding window: maintain batchSize blocks in-flight
  let
    refillThreshold = int(float(batchSize) * BatchRefillThreshold)
    refillSize = max(refillThreshold, 1)
    maxCallbackBlocks = min(batchSize, MaxOnBatchBlocks)

  var
    blockData: seq[bt.Block]
    failedBlocks = 0
    successfulBlocks = 0
    completedInWindow = 0

  var addresses = newSeqOfCap[BlockAddress](batchSize)
  for i in 0 ..< batchSize:
    if not iter.finished:
      let address = BlockAddress.init(cid, iter.next())
      if fetchLocal or not (await address in self.networkStore):
        addresses.add(address)

  var blockResults = await self.networkStore.getBlocks(addresses)

  while not blockResults.finished:
    without blk =? await blockResults.next(), err:
      inc(failedBlocks)
      continue

    inc(successfulBlocks)
    inc(completedInWindow)

    if not onBatch.isNil:
      blockData.add(blk)
      if blockData.len >= maxCallbackBlocks:
        if batchErr =? (await onBatch(blockData)).errorOption:
          return failure(batchErr)
        blockData = @[]

    if completedInWindow >= refillThreshold and not iter.finished:
      var refillAddresses = newSeqOfCap[BlockAddress](refillSize)
      for i in 0 ..< refillSize:
        if not iter.finished:
          let address = BlockAddress.init(cid, iter.next())
          if fetchLocal or not (await address in self.networkStore):
            refillAddresses.add(address)

      if refillAddresses.len > 0:
        blockResults =
          chain(blockResults, await self.networkStore.getBlocks(refillAddresses))
      completedInWindow = 0

  if failedBlocks > 0:
    return failure("Some blocks failed (Result) to fetch (" & $failedBlocks & ")")

  if not onBatch.isNil and blockData.len > 0:
    if batchErr =? (await onBatch(blockData)).errorOption:
      return failure(batchErr)

  success()

proc fetchBatched*(
    self: CodexNodeRef,
    manifest: Manifest,
    batchSize = DefaultFetchBatch,
    onBatch: BatchProc = nil,
    fetchLocal = true,
): Future[?!void] {.async: (raw: true, raises: [CancelledError]).} =
  ## Fetch manifest in batches of `batchSize`
  ##

  trace "Fetching blocks in batches of",
    size = batchSize, blocksCount = manifest.blocksCount

  let iter = Iter[int].new(0 ..< manifest.blocksCount)
  self.fetchBatched(manifest.treeCid, iter, batchSize, onBatch, fetchLocal)

proc fetchDatasetAsync*(
    self: CodexNodeRef, manifest: Manifest, fetchLocal = true
): Future[void] {.async: (raises: []).} =
  ## Asynchronously fetch a dataset in the background.
  ## This task will be tracked and cleaned up on node shutdown.
  ##
  try:
    if err =? (
      await self.fetchBatched(
        manifest = manifest, batchSize = DefaultFetchBatch, fetchLocal = fetchLocal
      )
    ).errorOption:
      error "Unable to fetch blocks", err = err.msg
  except CancelledError as exc:
    trace "Cancelled fetching blocks", exc = exc.msg

proc fetchDatasetAsyncTask*(self: CodexNodeRef, manifest: Manifest) =
  ## Start fetching a dataset in the background.
  ## The task will be tracked and cleaned up on node shutdown.
  ##
  self.trackedFutures.track(self.fetchDatasetAsync(manifest, fetchLocal = false))

proc streamSingleBlock(
    self: CodexNodeRef, cid: Cid
): Future[?!LPStream] {.async: (raises: [CancelledError]).} =
  ## Streams the contents of a single block.
  ##
  trace "Streaming single block", cid = cid

  let stream = BufferStream.new()

  without blk =? (await self.networkStore.getBlock(BlockAddress.init(cid))), err:
    return failure(err)

  proc streamOneBlock(): Future[void] {.async: (raises: []).} =
    try:
      defer:
        await stream.pushEof()
      await stream.pushData(blk.data)
    except CancelledError as exc:
      trace "Streaming block cancelled", cid, exc = exc.msg
    except LPStreamError as exc:
      trace "Unable to send block", cid, exc = exc.msg

  self.trackedFutures.track(streamOneBlock())
  LPStream(stream).success

proc streamEntireDataset(
    self: CodexNodeRef, manifest: Manifest, manifestCid: Cid
): Future[?!LPStream] {.async: (raises: [CancelledError]).} =
  ## Streams the contents of the entire dataset described by the manifest.
  ##
  trace "Retrieving blocks from manifest", manifestCid

  var jobs: seq[Future[void]]
  let stream = LPStream(StoreStream.new(self.networkStore, manifest, pad = false))

  jobs.add(self.fetchDatasetAsync(manifest, fetchLocal = false))

  # Monitor stream completion and cancel background jobs when done
  proc monitorStream() {.async: (raises: []).} =
    try:
      await stream.join()
    except CancelledError as exc:
      warn "Stream cancelled", exc = exc.msg
    finally:
      await noCancel allFutures(jobs.mapIt(it.cancelAndWait))

  self.trackedFutures.track(monitorStream())

  # Retrieve all blocks of the dataset sequentially from the local store or network
  trace "Creating store stream for manifest", manifestCid

  stream.success

proc retrieve*(
    self: CodexNodeRef, cid: Cid, local: bool = true
): Future[?!LPStream] {.async: (raises: [CancelledError]).} =
  ## Retrieve by Cid a single block or an entire dataset described by manifest
  ##

  if local and not await (cid in self.networkStore):
    return failure((ref BlockNotFoundError)(msg: "Block not found in local store"))

  without manifest =? (await self.fetchManifest(cid)), err:
    if err of AsyncTimeoutError:
      return failure(err)

    return await self.streamSingleBlock(cid)

  await self.streamEntireDataset(manifest, cid)

proc deleteSingleBlock(self: CodexNodeRef, cid: Cid): Future[?!void] {.async.} =
  if err =? (await self.networkStore.delBlock(cid)).errorOption:
    error "Error deleting block", cid, err = err.msg
    return failure(err)

  trace "Deleted block", cid
  return success()

proc deleteEntireDataset(self: CodexNodeRef, cid: Cid): Future[?!void] {.async.} =
  # Deletion is a strictly local operation
  var store = self.networkStore.localStore

  if not (await cid in store):
    # As per the contract for delete*, an absent dataset is not an error.
    return success()

  without manifestBlock =? await store.getBlock(cid), err:
    return failure(err)

  without manifest =? Manifest.decode(manifestBlock), err:
    return failure(err)

  let runtimeQuota = initDuration(milliseconds = 100)
  var lastIdle = getTime()
  for i in 0 ..< manifest.blocksCount:
    if (getTime() - lastIdle) >= runtimeQuota:
      await idleAsync()
      lastIdle = getTime()

    if err =? (await store.delBlock(manifest.treeCid, i)).errorOption:
      # The contract for delBlock is fuzzy, but we assume that if the block is
      # simply missing we won't get an error. This is a best effort operation and
      # can simply be retried.
      error "Failed to delete block within dataset", index = i, err = err.msg
      return failure(err)

  if err =? (await store.delBlock(cid)).errorOption:
    error "Error deleting manifest block", err = err.msg

  success()

proc delete*(
    self: CodexNodeRef, cid: Cid
): Future[?!void] {.async: (raises: [CatchableError]).} =
  ## Deletes a whole dataset, if Cid is a Manifest Cid, or a single block, if Cid a block Cid,
  ## from the underlying block store. This is a strictly local operation.
  ##
  ## Missing blocks in dataset deletes are ignored.
  ##

  without isManifest =? cid.isManifest, err:
    trace "Bad content type for CID:", cid = cid, err = err.msg
    return failure(err)

  if not isManifest:
    return await self.deleteSingleBlock(cid)

  await self.deleteEntireDataset(cid)

proc store*(
    self: CodexNodeRef,
    stream: LPStream,
    filename: ?string = string.none,
    mimetype: ?string = string.none,
    blockSize = DefaultBlockSize,
    onBlockStored: OnBlockStoredProc = nil,
): Future[?!Cid] {.async.} =
  ## Save stream contents as dataset with given blockSize
  ## to nodes's BlockStore, and return Cid of its manifest
  ##
  info "Storing data"

  let
    hcodec = Sha256HashCodec
    dataCodec = BlockCodec
    chunker = LPStreamChunker.new(stream, chunkSize = blockSize)

  var cids: seq[Cid]

  try:
    while (let chunk = await chunker.getBytes(); chunk.len > 0):
      without mhash =? MultiHash.digest($hcodec, chunk).mapFailure, err:
        return failure(err)

      without cid =? Cid.init(CIDv1, dataCodec, mhash).mapFailure, err:
        return failure(err)

      without blk =? bt.Block.new(cid, chunk, verify = false):
        return failure("Unable to init block from chunk!")

      cids.add(cid)

      if err =? (await self.networkStore.putBlock(blk)).errorOption:
        error "Unable to store block", cid = blk.cid, err = err.msg
        return failure(&"Unable to store block {blk.cid}")

      if not onBlockStored.isNil:
        onBlockStored(chunk)
  except CancelledError as exc:
    raise exc
  except CatchableError as exc:
    return failure(exc.msg)
  finally:
    await stream.close()

  without tree =? (await CodexTree.init(self.taskPool, cids)), err:
    return failure(err)

  without treeCid =? tree.rootCid(CIDv1, dataCodec), err:
    return failure(err)

  for index, cid in cids:
    without proof =? tree.getProof(index), err:
      return failure(err)
    if err =?
        (await self.networkStore.putCidAndProof(treeCid, index, cid, proof)).errorOption:
      # TODO add log here
      return failure(err)

  let manifest = Manifest.new(
    treeCid = treeCid,
    blockSize = blockSize,
    datasetSize = NBytes(chunker.offset),
    version = CIDv1,
    hcodec = hcodec,
    codec = dataCodec,
    filename = filename,
    mimetype = mimetype,
  )

  without manifestBlk =? await self.storeManifest(manifest), err:
    error "Unable to store manifest"
    return failure(err)

  info "Stored data",
    manifestCid = manifestBlk.cid,
    treeCid = treeCid,
    blocks = manifest.blocksCount,
    datasetSize = manifest.datasetSize,
    filename = manifest.filename,
    mimetype = manifest.mimetype

  return manifestBlk.cid.success

proc iterateManifests*(self: CodexNodeRef, onManifest: OnManifest) {.async.} =
  without cidsIter =? await self.networkStore.listBlocks(BlockType.Manifest):
    warn "Failed to listBlocks"
    return

  for c in cidsIter:
    if cid =? await c:
      without blk =? await self.networkStore.getBlock(cid):
        warn "Failed to get manifest block by cid", cid
        return

      without manifest =? Manifest.decode(blk):
        warn "Failed to decode manifest", cid
        return

      onManifest(cid, manifest)

proc onExpiryUpdate(
    self: CodexNodeRef, rootCid: Cid, expiry: SecondsSince1970
): Future[?!void] {.async: (raises: [CancelledError]).} =
  return await self.updateExpiry(rootCid, expiry)

proc start*(self: CodexNodeRef) {.async.} =
  if not self.engine.isNil:
    await self.engine.start()

  if not self.discovery.isNil:
    await self.discovery.start()

  if not self.clock.isNil:
    await self.clock.start()

  self.networkId = self.switch.peerInfo.peerId
  notice "Started Storage node", id = self.networkId, addrs = self.switch.peerInfo.addrs

proc stop*(self: CodexNodeRef) {.async.} =
  trace "Stopping node"

  await self.trackedFutures.cancelTracked()

  if not self.engine.isNil:
    await self.engine.stop()

  if not self.discovery.isNil:
    await self.discovery.stop()

  if not self.clock.isNil:
    await self.clock.stop()

proc close*(self: CodexNodeRef) {.async.} =
  if not self.networkStore.isNil:
    await self.networkStore.close

proc new*(
    T: type CodexNodeRef,
    switch: Switch,
    networkStore: NetworkStore,
    engine: BlockExcEngine,
    discovery: Discovery,
    taskpool: Taskpool,
): CodexNodeRef =
  ## Create new instance of a Codex self, call `start` to run it
  ##

  CodexNodeRef(
    switch: switch,
    networkStore: networkStore,
    engine: engine,
    discovery: discovery,
    taskPool: taskpool,
    trackedFutures: TrackedFutures(),
  )

proc hasLocalBlock*(
    self: CodexNodeRef, cid: Cid
): Future[bool] {.async: (raises: [CancelledError]).} =
  ## Returns true if the given Cid is present in the local store

  return await (cid in self.networkStore.localStore)
