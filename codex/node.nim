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
  FetchBatch = 100

type
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

# TODO: move code that retrieves blocks in manifest into blockstore
proc retrieve*(
  node: CodexNodeRef,
  cid: Cid): Future[?!LPStream] {.async.} =

  trace "Received retrieval request", cid
  without blkOrNone =? await node.blockStore.getBlock(cid), error:
    return failure(error)

  without blk =? blkOrNone:
    trace "Block not found", cid
    return failure("Block not found")

  if manifest =? Manifest.decode(blk.data, blk.cid):

    if manifest.protected:
      proc erasureJob(): Future[void] {.async.} =
        try:
          without res =? (await node.erasure.decode(manifest)), error: # spawn an erasure decoding job
            trace "Unable to erasure decode manifest", cid, exc = error.msg
        except CatchableError as exc:
          trace "Exception decoding manifest", cid

      asyncSpawn erasureJob()

    proc prefetchBlocks() {.async.} =
      ## Initiates requests to all blocks in the manifest
      ##
      try:
        let
          batch = max(1, manifest.blocks.len div FetchBatch)
        trace "Prefetching in batches of", FetchBatch
        for blks in manifest.blocks.distribute(batch, true):
          discard await allFinished(
            blks.mapIt( node.blockStore.getBlock( it ) ))
      except CatchableError as exc:
        trace "Exception prefetching blocks", exc = exc.msg

    asyncSpawn prefetchBlocks()
    return LPStream(StoreStream.new(node.blockStore, manifest)).success

  let
    stream = BufferStream.new()

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

proc store*(
  node: CodexNodeRef,
  stream: LPStream): Future[?!Cid] {.async.} =
  trace "Storing data"

  without var blockManifest =? Manifest.new():
    return failure("Unable to create Block Set")

  let
    chunker = LPStreamChunker.new(stream, chunkSize = BlockSize)

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

proc store(node: CodexNodeRef, cid: Cid): Future[?!void] {.async.}

proc store(node: CodexNodeRef, cids: seq[Cid]): Future[?!void] {.async.} =
  ## Retrieves multiple datasets from the network, and stores them locally

  let batches = max(1, cids.len div FetchBatch)
  for batch in cids.distribute(batches, true):
    let results = await allFinished(cids.mapIt(node.store(it)))
    for future in results:
      let res = await future
      if res.isFailure:
        return failure res.error

  return success()

proc store(node: CodexNodeRef, cid: Cid): Future[?!void] {.async.} =
  ## Retrieves dataset from the network, and stores it locally

  if node.blockstore.hasBlock(cid):
    return success()

  without blk =? await node.blockstore.getBlock(cid):
    return failure newException(CodexError, "Unable to retrieve block " & $cid)

  if not (await node.blockstore.putBlock(blk)):
    return failure newException(CodexError, "Unable to store block " & $cid)

  if manifest =? Manifest.decode(blk.data, blk.cid):

    let res = await node.store(manifest.blocks)
    if res.isFailure:
      return failure res.error

proc requestStorage*(self: CodexNodeRef,
                     cid: Cid,
                     duration: UInt256,
                     nodes: uint,
                     tolerance: uint,
                     maxPrice: UInt256,
                     expiry = UInt256.none): Future[?!array[32, byte]] {.async.} =
  ## Initiate a request for storage sequence, this might
  ## be a multistep procedure.
  ##
  ## Roughly the flow is as follows:
  ## - Get the original cid from the store (should have already been uploaded)
  ## - Erasure code it according to the nodes and tolerance parameters
  ## - Run the PoR setup on the erasure dataset
  ## - Call into the marketplace and purchasing contracts
  ##
  trace "Received a request for storage!", cid, duration, nodes, tolerance, maxPrice

  without contracts =? self.contracts:
    trace "Purchasing not available"
    return failure "Purchasing not available"

  without blkOrNone =? (await self.blockStore.getBlock(cid)), error:
    trace "Unable to retrieve manifest block", cid
    return failure(error)

  without blk =? blkOrNone:
    trace "Manifest block not found", cid
    return failure("Manifest block not found")

  without mc =? blk.cid.contentType():
    trace "Couldn't identify Cid!", cid
    return failure("Couldn't identify Cid! " & $cid)

  # if we got a manifest, stream the blocks
  if $mc notin ManifestContainers:
    trace "Not a manifest type!", cid, mc = $mc
    return failure("Not a manifest type!")

  without var manifest =? Manifest.decode(blk.data), error:
    trace "Unable to decode manifest from block", cid
    return failure(error)

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
      size: encoded.size.u256,
      duration: duration,
      maxPrice: maxPrice
    ),
    content: StorageContent(
      cid: $encodedBlk.cid,
      erasure: StorageErasure(
        totalChunks: encoded.len.uint64,
        totalNodes: 1,  # TODO: store on multiple nodes
        nodeId: 0       # TODO: store on multiple nodes
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
  contracts: ?ContractInteractions): T =
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
    contracts.sales.onStore = proc(cid: string, _: Availability) {.async.} =
      # store data in local storage
      (await node.store(Cid.init(cid).tryGet())).tryGet()
    contracts.sales.onClear = proc(availability: Availability, request: StorageRequest) =
      # TODO: remove data from local storage
      discard
    contracts.sales.onProve = proc(cid: string): Future[seq[byte]] {.async.} =
      # TODO: generate proof
      return @[42'u8]
    await contracts.start()

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
