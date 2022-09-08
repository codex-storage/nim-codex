## Nim-Codex
## Copyright (c) 2021 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import std/options
import std/tables
import std/sequtils

import pkg/questionable
import pkg/questionable/results
import pkg/chronicles
import pkg/chronos
import pkg/libp2p

# TODO: remove once exported by libp2p
import pkg/libp2p/routing_record
import pkg/libp2p/signed_envelope

import ./chunker
import ./blocktype as bt
import ./manifest
import ./stores/blockstore
import ./blockexchange
import ./streams
import ./erasure
import ./discovery
import ./contracts

logScope:
  topics = "codex node"

const
  FetchBatch = 200

type
  BatchProc* = proc(blocks: seq[bt.Block]): Future[void] {.gcsafe, raises: [Defect].}

  CodexError = object of CatchableError

  CodexNodeRef* = ref object
    switch*: Switch
    networkId*: PeerID
    blockStore*: BlockStore
    engine*: BlockExcEngine
    erasure*: Erasure
    discovery*: Discovery
    contracts*: ?ContractInteractions

proc findPeer*(
  node: CodexNodeRef,
  peerId: PeerID): Future[?PeerRecord] {.async.} =
  return await node.discovery.findPeer(peerId)

proc connect*(
  node: CodexNodeRef,
  peerId: PeerID,
  addrs: seq[MultiAddress]): Future[void] =
  node.switch.connect(peerId, addrs)

proc fetchManifest*(
  node: CodexNodeRef,
  cid: Cid): Future[?!Manifest] {.async.} =
  ## Fetch and decode a manifest block
  ##

  without contentType =? cid.contentType() and
          containerType =? ManifestContainers.?[$contentType]:
    return failure "CID has invalid content type for manifest"

  trace "Received retrieval request", cid

  without blk =? await node.blockStore.getBlock(cid), error:
    return failure error

  without manifest =? Manifest.decode(blk):
    return failure(
      newException(CodexError, "Unable to decode as manifest"))

  return manifest.success

proc fetchBatched*(
  node: CodexNodeRef,
  manifest: Manifest,
  batchSize = FetchBatch,
  onBatch: BatchProc = nil): Future[?!void] {.async, gcsafe.} =
  ## Fetch manifest in batches of `batchSize`
  ##

  let
    batches =
      (manifest.blocks.len div batchSize) +
      (manifest.blocks.len mod batchSize)

  trace "Fetching blocks in batches of", size = batchSize
  for blks in manifest.blocks.distribute(max(1, batches), true):
    try:
      let
        blocks = blks.mapIt(node.blockStore.getBlock( it ))

      await allFuturesThrowing(allFinished(blocks))
      if not onBatch.isNil:
        await onBatch(blocks.mapIt( it.read.get ))
    except CancelledError as exc:
      raise exc
    except CatchableError as exc:
      return failure(exc.msg)

  return success()

proc retrieve*(
  node: CodexNodeRef,
  cid: Cid): Future[?!LPStream] {.async.} =
  ## Retrieve by Cid a single block or an entire dataset described by manifest
  ##

  if manifest =? (await node.fetchManifest(cid)):
    if manifest.protected:
      # Retrieve, decode and save to the local store all EС groups
      proc erasureJob(): Future[void] {.async.} =
        try:
          # Spawn an erasure decoding job
          without res =? (await node.erasure.decode(manifest)), error:
            trace "Unable to erasure decode manifest", cid, exc = error.msg
        except CatchableError as exc:
          trace "Exception decoding manifest", cid
      #
      asyncSpawn erasureJob()
    else:
      # Prefetch the entire dataset into the local store
      proc prefetchBlocks() {.async, raises: [Defect].} =
        try:
          discard await node.fetchBatched(manifest)
        except CatchableError as exc:
          trace "Exception prefetching blocks", exc = exc.msg
      #
      #asyncSpawn prefetchBlocks()
    #
    # Retrieve all blocks of the dataset sequentially from the local store or network
    return LPStream(StoreStream.new(node.blockStore, manifest, pad = false)).success

  let
    stream = BufferStream.new()

  if blkOrNone =? (await node.blockStore.getBlock(cid)) and blk =? blkOrNone:
    proc streamOneBlock(): Future[void] {.async.} =
      try:
        await stream.pushData(blk.data)
      except CatchableError as exc:
        trace "Unable to send block", cid
        discard
      finally:
        await stream.pushEof()

    asyncSpawn streamOneBlock()
    return LPStream(stream).success()

  return failure("Unable to retrieve Cid!")

proc store*(
  node: CodexNodeRef,
  stream: LPStream,
  blockSize = BlockSize): Future[?!Cid] {.async.} =
  ## Save stream contents as dataset with given blockSize
  ## to nodes's BlockStore, and return Cid of its manifest
  ##
  trace "Storing data"

  without var blockManifest =? Manifest.new(blockSize = blockSize):
    return failure("Unable to create Block Set")

  # Manifest and chunker should use the same blockSize
  let chunker = LPStreamChunker.new(stream, chunkSize = blockSize)

  try:
    while (
      let chunk = await chunker.getBytes();
      chunk.len > 0):

      trace "Got data from stream", len = chunk.len
      without blk =? bt.Block.new(chunk):
        return failure("Unable to init block from chunk!")

      blockManifest.add(blk.cid)
      if isErr (await node.blockStore.putBlock(blk)):
        # trace "Unable to store block", cid = blk.cid
        return failure("Unable to store block " & $blk.cid)

  except CancelledError as exc:
    raise exc
  except CatchableError as exc:
    return failure(exc.msg)
  finally:
    await stream.close()

  # Generate manifest
  blockManifest.originalBytes = chunker.offset  # store the exact file size
  without data =? blockManifest.encode():
    return failure(
      newException(CodexError, "Could not generate dataset manifest!"))

  # Store as a dag-pb block
  without manifest =? bt.Block.new(data = data, codec = DagPBCodec):
    trace "Unable to init block from manifest data!"
    return failure("Unable to init block from manifest data!")

  if isErr (await node.blockStore.putBlock(manifest)):
    trace "Unable to store manifest", cid = manifest.cid
    return failure("Unable to store manifest " & $manifest.cid)

  without cid =? blockManifest.cid, error:
    trace "Unable to generate manifest Cid!", exc = error.msg
    return failure(error.msg)

  trace "Stored data", manifestCid = manifest.cid,
                       contentCid = cid,
                       blocks = blockManifest.len

  return manifest.cid.success

proc requestStorage*(self: CodexNodeRef,
                     cid: Cid,
                     duration: UInt256,
                     nodes: uint,
                     tolerance: uint,
                     reward: UInt256,
                     expiry = UInt256.none): Future[?!PurchaseId] {.async.} =
  ## Initiate a request for storage sequence, this might
  ## be a multistep procedure.
  ##
  ## Roughly the flow is as follows:
  ## - Get the original cid from the store (should have already been uploaded)
  ## - Erasure code it according to the nodes and tolerance parameters
  ## - Run the PoR setup on the erasure dataset
  ## - Call into the marketplace and purchasing contracts
  ##
  trace "Received a request for storage!", cid, duration, nodes, tolerance, reward

  without contracts =? self.contracts:
    trace "Purchasing not available"
    return failure "Purchasing not available"

  without manifest =? await self.fetchManifest(cid), error:
    trace "Unable to fetch manifest for cid", cid
    raise error

  # Erasure code the dataset according to provided parameters
  without encoded =? (await self.erasure.encode(manifest, nodes.int, tolerance.int)), error:
    trace "Unable to erasure code dataset", cid
    return failure(error)

  without encodedData =? encoded.encode(), error:
    trace "Unable to encode protected manifest"
    return failure(error)

  without encodedBlk =? bt.Block.new(data = encodedData, codec = DagPBCodec), error:
    trace "Unable to create block from encoded manifest"
    return failure(error)

  if isErr (await self.blockStore.putBlock(encodedBlk)):
    trace "Unable to store encoded manifest block", cid = encodedBlk.cid
    return failure("Unable to store encoded manifest block")

  let request = StorageRequest(
    ask: StorageAsk(
      slots: nodes + tolerance,
      slotSize: (encoded.blockSize * encoded.steps).u256,
      duration: duration,
      reward: reward
    ),
    content: StorageContent(
      cid: $encodedBlk.cid,
      erasure: StorageErasure(
        totalChunks: encoded.len.uint64,
      ),
      por: StoragePor(
        u: @[],         # TODO: PoR setup
        publicKey: @[], # TODO: PoR setup
        name: @[]       # TODO: PoR setup
      )
    ),
    expiry: expiry |? 0.u256
  )

  let purchase = contracts.purchasing.purchase(request)
  return success purchase.id

proc new*(
  T: type CodexNodeRef,
  switch: Switch,
  store: BlockStore,
  engine: BlockExcEngine,
  erasure: Erasure,
  discovery: Discovery,
  contracts = ContractInteractions.none): T =
  T(
    switch: switch,
    blockStore: store,
    engine: engine,
    erasure: erasure,
    discovery: discovery,
    contracts: contracts)

proc start*(node: CodexNodeRef) {.async.} =
  if not node.switch.isNil:
    await node.switch.start()

  if not node.engine.isNil:
    await node.engine.start()

  if not node.erasure.isNil:
    await node.erasure.start()

  if not node.discovery.isNil:
    await node.discovery.start()

  if contracts =? node.contracts:
    # TODO: remove Sales callbacks, pass BlockStore and StorageProofs instead
    contracts.sales.onStore = proc(request: StorageRequest,
                                   slot: UInt256,
                                   availability: Availability) {.async.} =
      ## store data in local storage
      ##

      without cid =? Cid.init(request.content.cid):
        trace "Unable to parse Cid", cid
        raise newException(CodexError, "Unable to parse Cid")

      without manifest =? await node.fetchManifest(cid), error:
        trace "Unable to fetch manifest for cid", cid
        raise error

      trace "Fetching block for manifest", cid
      # TODO: This will probably require a call to `getBlock` either way,
      # since fetching of blocks will have to be selective according
      # to a combination of parameters, such as node slot position
      # and dataset geometry
      let fetchRes = await node.fetchBatched(manifest)
      if fetchRes.isErr:
        raise newException(CodexError, "Unable to retrieve blocks")

    contracts.sales.onClear = proc(availability: Availability, request: StorageRequest) =
      # TODO: remove data from local storage
      discard
    contracts.sales.onProve = proc(request: StorageRequest,
                                   slot: UInt256): Future[seq[byte]] {.async.} =
      # TODO: generate proof
      return @[42'u8]

    try:
      await contracts.start()
    except CatchableError as error:
      error "Unable to start contract interactions: ", error=error.msg
      node.contracts = ContractInteractions.none

  node.networkId = node.switch.peerInfo.peerId
  notice "Started codex node", id = $node.networkId, addrs = node.switch.peerInfo.addrs

proc stop*(node: CodexNodeRef) {.async.} =
  trace "Stopping node"

  if not node.engine.isNil:
    await node.engine.stop()

  if not node.switch.isNil:
    await node.switch.stop()

  if not node.erasure.isNil:
    await node.erasure.stop()

  if not node.discovery.isNil:
    await node.discovery.stop()

  if contracts =? node.contracts:
    await contracts.stop()

  if not node.blockStore.isNil:
    await node.blockStore.close
