## Nim-Codex
## Copyright (c) 2021 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import std/options
import std/sequtils
import std/strformat
import std/sugar

import pkg/questionable
import pkg/questionable/results
import pkg/chronicles
import pkg/chronos
import pkg/poseidon2

import pkg/libp2p/[switch, multicodec, multihash]
import pkg/libp2p/stream/bufferstream

# TODO: remove once exported by libp2p
import pkg/libp2p/routing_record
import pkg/libp2p/signed_envelope

import ./chunker
import ./slots
import ./clock
import ./blocktype as bt
import ./manifest
import ./merkletree
import ./stores/blockstore
import ./blockexchange
import ./streams
import ./erasure
import ./discovery
import ./contracts
import ./node/batch
import ./utils
import ./errors
import ./merkletree

export batch

logScope:
  topics = "codex node"

const
  FetchBatch = 200

type
  CodexError = object of CatchableError

  Contracts* = tuple
    client: ?ClientInteractions
    host: ?HostInteractions
    validator: ?ValidatorInteractions

  CodexNodeRef* = ref object
    switch: Switch
    networkId: PeerId
    blockStore: BlockStore
    engine: BlockExcEngine
    erasure: Erasure
    discovery: Discovery
    contracts*: Contracts
    clock*: Clock

  OnManifest* = proc(cid: Cid, manifest: Manifest): void {.gcsafe, closure.}

func switch*(self: CodexNodeRef): Switch =
  return self.switch

func blockStore*(self: CodexNodeRef): BlockStore =
  return self.blockStore

func engine*(self: CodexNodeRef): BlockExcEngine =
  return self.engine

func erasure*(self: CodexNodeRef): Erasure =
  return self.erasure

func discovery*(self: CodexNodeRef): Discovery =
  return self.discovery

proc storeManifest*(self: CodexNodeRef, manifest: Manifest): Future[?!bt.Block] {.async.} =
  without encodedVerifiable =? manifest.encode(), err:
    trace "Unable to encode manifest"
    return failure(err)

  without blk =? bt.Block.new(data = encodedVerifiable, codec = ManifestCodec), error:
    trace "Unable to create block from manifest"
    return failure(error)

  if err =? (await self.blockStore.putBlock(blk)).errorOption:
    trace "Unable to store manifest block", cid = blk.cid, err = err.msg
    return failure(err)

  success blk

proc findPeer*(
  node: CodexNodeRef,
  peerId: PeerId): Future[?PeerRecord] {.async.} =
  ## Find peer using the discovery service from the given CodexNode
  ##
  return await node.discovery.findPeer(peerId)

proc connect*(
  node: CodexNodeRef,
  peerId: PeerId,
  addrs: seq[MultiAddress]
): Future[void] =
  node.switch.connect(peerId, addrs)

proc fetchManifest*(
  node: CodexNodeRef,
  cid: Cid): Future[?!Manifest] {.async.} =
  ## Fetch and decode a manifest block
  ##

  if err =? cid.isManifest.errorOption:
    return failure "CID has invalid content type for manifest {$cid}"

  trace "Retrieving manifest for cid", cid

  without blk =? await node.blockStore.getBlock(BlockAddress.init(cid)), err:
    trace "Error retrieve manifest block", cid, err = err.msg
    return failure err

  trace "Decoding manifest for cid", cid

  without manifest =? Manifest.decode(blk), err:
    trace "Unable to decode as manifest", err = err.msg
    return failure("Unable to decode as manifest")

  trace "Decoded manifest", cid

  return manifest.success

proc updateExpiry*(node: CodexNodeRef, manifestCid: Cid, expiry: SecondsSince1970): Future[?!void] {.async.} =
  without manifest =? await node.fetchManifest(manifestCid), error:
    trace "Unable to fetch manifest for cid", manifestCid
    return failure(error)

  try:
      let ensuringFutures = Iter.fromSlice(0..<manifest.blocksCount)
                               .mapIt(node.blockStore.ensureExpiry( manifest.treeCid, it, expiry ))
      await allFuturesThrowing(ensuringFutures)
  except CancelledError as exc:
    raise exc
  except CatchableError as exc:
    return failure(exc.msg)

  return success()

proc fetchBatched*(
  node: CodexNodeRef,
  manifest: Manifest,
  batchSize = FetchBatch,
  onBatch: BatchProc = nil): Future[?!void] {.async, gcsafe.} =
  ## Fetch manifest in batches of `batchSize`
  ##

  let batchCount = divUp(manifest.blocksCount, batchSize)

  trace "Fetching blocks in batches of", size = batchSize

  let iter = Iter.fromSlice(0..<manifest.blocksCount)
    .map((i: int) => node.blockStore.getBlock(BlockAddress.init(manifest.treeCid, i)))

  for batchNum in 0..<batchCount:
    let blocks = collect:
      for i in 0..<batchSize:
        if not iter.finished:
          iter.next()

    if blocksErr =? (await allFutureResult(blocks)).errorOption:
      return failure(blocksErr)

    if not onBatch.isNil and batchErr =? (await onBatch(blocks.mapIt( it.read.get ))).errorOption:
      return failure(batchErr)

  return success()

proc retrieve*(
  node: CodexNodeRef,
  cid: Cid,
  local: bool = true): Future[?!LPStream] {.async.} =
  ## Retrieve by Cid a single block or an entire dataset described by manifest
  ##

  if local and not await (cid in node.blockStore):
    return failure((ref BlockNotFoundError)(msg: "Block not found in local store"))

  if manifest =? (await node.fetchManifest(cid)):
    trace "Retrieving blocks from manifest", cid
    if manifest.protected:
      # Retrieve, decode and save to the local store all EС groups
      proc erasureJob(): Future[void] {.async.} =
        try:
          # Spawn an erasure decoding job
          without res =? (await node.erasure.decode(manifest)), error:
            trace "Unable to erasure decode manifest", cid, exc = error.msg
        except CatchableError as exc:
          trace "Exception decoding manifest", cid, exc = exc.msg

      asyncSpawn erasureJob()

    # Retrieve all blocks of the dataset sequentially from the local store or network
    trace "Creating store stream for manifest", cid
    LPStream(StoreStream.new(node.blockStore, manifest, pad = false)).success
  else:
    let
      stream = BufferStream.new()

    without blk =? (await node.blockStore.getBlock(BlockAddress.init(cid))), err:
      return failure(err)

    proc streamOneBlock(): Future[void] {.async.} =
      try:
        await stream.pushData(blk.data)
      except CatchableError as exc:
        trace "Unable to send block", cid, exc = exc.msg
        discard
      finally:
        await stream.pushEof()

    asyncSpawn streamOneBlock()
    LPStream(stream).success()

proc store*(
  self: CodexNodeRef,
  stream: LPStream,
  blockSize = DefaultBlockSize): Future[?!Cid] {.async.} =
  ## Save stream contents as dataset with given blockSize
  ## to nodes's BlockStore, and return Cid of its manifest
  ##
  trace "Storing data"

  let
    hcodec = Sha256HashCodec
    dataCodec = BlockCodec
    chunker = LPStreamChunker.new(stream, chunkSize = blockSize)

  var cids: seq[Cid]

  try:
    while (
      let chunk = await chunker.getBytes();
      chunk.len > 0):

      trace "Got data from stream", len = chunk.len

      without mhash =? MultiHash.digest($hcodec, chunk).mapFailure, err:
        return failure(err)

      without cid =? Cid.init(CIDv1, dataCodec, mhash).mapFailure, err:
        return failure(err)

      without blk =? bt.Block.new(cid, chunk, verify = false):
        return failure("Unable to init block from chunk!")

      cids.add(cid)

      if err =? (await self.blockStore.putBlock(blk)).errorOption:
        trace "Unable to store block", cid = blk.cid, err = err.msg
        return failure(&"Unable to store block {blk.cid}")
  except CancelledError as exc:
    raise exc
  except CatchableError as exc:
    return failure(exc.msg)
  finally:
    await stream.close()

  without tree =? CodexTree.init(cids), err:
    return failure(err)

  without treeCid =? tree.rootCid(CIDv1, dataCodec), err:
    return failure(err)

  for index, cid in cids:
    without proof =? tree.getProof(index), err:
      return failure(err)
    if err =? (await self.blockStore.putCidAndProof(treeCid, index, cid, proof)).errorOption:
      # TODO add log here
      return failure(err)

  let manifest = Manifest.new(
    treeCid = treeCid,
    blockSize = blockSize,
    datasetSize = NBytes(chunker.offset),
    version = CIDv1,
    hcodec = hcodec,
    codec = dataCodec)

  without manifestBlk =? await self.storeManifest(manifest), err:
    trace "Unable to store manifest"
    return failure(err)

  info "Stored data", manifestCid = manifestBlk.cid,
                      treeCid = treeCid,
                      blocks = manifest.blocksCount,
                      datasetSize = manifest.datasetSize

  # Announce manifest
  await self.discovery.provide(manifestBlk.cid)
  await self.discovery.provide(treeCid)

  return manifestBlk.cid.success

proc iterateManifests*(node: CodexNodeRef, onManifest: OnManifest) {.async.} =
  without cids =? await node.blockStore.listBlocks(BlockType.Manifest):
    warn "Failed to listBlocks"
    return

  for c in cids:
    if cid =? await c:
      without blk =? await node.blockStore.getBlock(cid):
        warn "Failed to get manifest block by cid", cid
        return

      without manifest =? Manifest.decode(blk):
        warn "Failed to decode manifest", cid
        return

      onManifest(cid, manifest)

proc setupRequest(
  self: CodexNodeRef,
  cid: Cid,
  duration: UInt256,
  proofProbability: UInt256,
  nodes: uint,
  tolerance: uint,
  reward: UInt256,
  collateral: UInt256,
  expiry:  UInt256): Future[?!StorageRequest] {.async.} =
  ## Setup slots for a given dataset
  ##

  let
    ecK = nodes - tolerance
    ecM = tolerance

  logScope:
    cid               = cid
    duration          = duration
    nodes             = nodes
    tolerance         = tolerance
    reward            = reward
    proofProbability  = proofProbability
    collateral        = collateral
    expiry            = expiry
    ecK               = ecK
    ecM               = ecM

  trace "Setting up slots"

  without manifest =? await self.fetchManifest(cid), error:
    trace "Unable to fetch manifest for cid"
    return failure error

  # Erasure code the dataset according to provided parameters
  without encoded =? (await self.erasure.encode(manifest, ecK, ecM)), error:
    trace "Unable to erasure code dataset"
    return failure(error)

  without builder =? SlotsBuilder.new(self.blockStore, encoded), err:
    trace "Unable to create slot builder"
    return failure(err)

  without verifiable =? (await builder.buildManifest()), err:
    trace "Unable to build verifiable manifest"
    return failure(err)

  without manifestBlk =? await self.storeManifest(verifiable), err:
    trace "Unable to store verifiable manifest"
    return failure(err)

  let
    verifyRoot =
      if builder.verifyRoot.isNone:
          return failure("No slots root")
        else:
          builder.verifyRoot.get.toBytes

    slotRoots =
      if builder.slotRoots.len <= 0:
          return failure("Slots are empty")
        else:
          builder.slotRoots.mapIt( it.toBytes )

    request = StorageRequest(
      ask: StorageAsk(
        slots: verifiable.numSlots.uint64,
        slotSize: builder.slotBytes.uint.u256,
        duration: duration,
        proofProbability: proofProbability,
        reward: reward,
        collateral: collateral,
        maxSlotLoss: tolerance
      ),
      content: StorageContent(
        cid: $manifestBlk.cid, # TODO: why string?
        merkleRoot: verifyRoot
      ),
      expiry: expiry
    )

  trace "Request created", request = $request
  success request

proc requestStorage*(
  self: CodexNodeRef,
  cid: Cid,
  duration: UInt256,
  proofProbability: UInt256,
  nodes: uint,
  tolerance: uint,
  reward: UInt256,
  collateral: UInt256,
  expiry:  UInt256): Future[?!PurchaseId] {.async.} =
  ## Initiate a request for storage sequence, this might
  ## be a multistep procedure.
  ##

  logScope:
    cid               = cid
    duration          = duration
    nodes             = nodes
    tolerance         = tolerance
    reward            = reward
    proofProbability  = proofProbability
    collateral        = collateral
    expiry            = expiry

  trace "Received a request for storage!"

  without contracts =? self.contracts.client:
    trace "Purchasing not available"
    return failure "Purchasing not available"

  without request =?
    (await self.setupRequest(
      cid,
      duration,
      proofProbability,
      nodes,
      tolerance,
      reward,
      collateral,
      expiry)), err:
    trace "Unable to setup request"
    return failure err

  let purchase = await contracts.purchasing.purchase(request)
  success purchase.id

proc new*(
  T: type CodexNodeRef,
  switch: Switch,
  store: BlockStore,
  engine: BlockExcEngine,
  erasure: Erasure,
  discovery: Discovery,
  contracts = Contracts.default): CodexNodeRef =
  ## Create new instance of a Codex node, call `start` to run it
  ##
  CodexNodeRef(
    switch: switch,
    blockStore: store,
    engine: engine,
    erasure: erasure,
    discovery: discovery,
    contracts: contracts)

proc start*(node: CodexNodeRef) {.async.} =
  if not node.engine.isNil:
    await node.engine.start()

  if not node.erasure.isNil:
    await node.erasure.start()

  if not node.discovery.isNil:
    await node.discovery.start()

  if not node.clock.isNil:
    await node.clock.start()

  if hostContracts =? node.contracts.host:
    # TODO: remove Sales callbacks, pass BlockStore and StorageProofs instead
    hostContracts.sales.onStore = proc(request: StorageRequest,
                                       slot: UInt256,
                                       onBatch: BatchProc): Future[?!void] {.async.} =
      ## store data in local storage
      ##

      without cid =? Cid.init(request.content.cid):
        trace "Unable to parse Cid", cid
        let error = newException(CodexError, "Unable to parse Cid")
        return failure(error)

      without manifest =? await node.fetchManifest(cid), error:
        trace "Unable to fetch manifest for cid", cid
        return failure(error)

      trace "Fetching block for manifest", cid
      let expiry = request.expiry.toSecondsSince1970
      proc expiryUpdateOnBatch(blocks: seq[bt.Block]): Future[?!void] {.async.} =
        let ensureExpiryFutures = blocks.mapIt(node.blockStore.ensureExpiry(it.cid, expiry))
        if updateExpiryErr =? (await allFutureResult(ensureExpiryFutures)).errorOption:
          return failure(updateExpiryErr)

        if not onBatch.isNil and onBatchErr =? (await onBatch(blocks)).errorOption:
          return failure(onBatchErr)

        return success()

      if fetchErr =? (await node.fetchBatched(manifest, onBatch = expiryUpdateOnBatch)).errorOption:
        let error = newException(CodexError, "Unable to retrieve blocks")
        error.parent = fetchErr
        return failure(error)

      return success()

    hostContracts.sales.onExpiryUpdate = proc(rootCid: string, expiry: SecondsSince1970): Future[?!void] {.async.} =
      without cid =? Cid.init(rootCid):
        trace "Unable to parse Cid", cid
        let error = newException(CodexError, "Unable to parse Cid")
        return failure(error)

      return await node.updateExpiry(cid, expiry)

    hostContracts.sales.onClear = proc(request: StorageRequest,
                                       slotIndex: UInt256) =
      # TODO: remove data from local storage
      discard

    hostContracts.sales.onProve = proc(slot: Slot, challenge: ProofChallenge): Future[seq[byte]] {.async.} =
      # TODO: generate proof
      return @[42'u8]

    try:
      await hostContracts.start()
    except CatchableError as error:
      error "Unable to start host contract interactions", error=error.msg
      node.contracts.host = HostInteractions.none

  if clientContracts =? node.contracts.client:
    try:
      await clientContracts.start()
    except CatchableError as error:
      error "Unable to start client contract interactions: ", error=error.msg
      node.contracts.client = ClientInteractions.none

  if validatorContracts =? node.contracts.validator:
    try:
      await validatorContracts.start()
    except CatchableError as error:
      error "Unable to start validator contract interactions: ", error=error.msg
      node.contracts.validator = ValidatorInteractions.none

  node.networkId = node.switch.peerInfo.peerId
  notice "Started codex node", id = $node.networkId, addrs = node.switch.peerInfo.addrs

proc stop*(node: CodexNodeRef) {.async.} =
  trace "Stopping node"

  if not node.engine.isNil:
    await node.engine.stop()

  if not node.erasure.isNil:
    await node.erasure.stop()

  if not node.discovery.isNil:
    await node.discovery.stop()

  if not node.clock.isNil:
    await node.clock.stop()

  if clientContracts =? node.contracts.client:
    await clientContracts.stop()

  if hostContracts =? node.contracts.host:
    await hostContracts.stop()

  if validatorContracts =? node.contracts.validator:
    await validatorContracts.stop()

  if not node.blockStore.isNil:
    await node.blockStore.close
