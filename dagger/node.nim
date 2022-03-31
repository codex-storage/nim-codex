## Nim-Dagger
## Copyright (c) 2021 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import std/options
import std/tables

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

logScope:
  topics = "dagger node"

type
  DaggerError = object of CatchableError

  DaggerNodeRef* = ref object
    switch*: Switch
    networkId*: PeerID
    blockStore*: BlockStore
    engine*: BlockExcEngine
    erasure*: Erasure

proc start*(node: DaggerNodeRef) {.async.} =
  await node.switch.start()
  await node.engine.start()
  await node.erasure.start()

  node.networkId = node.switch.peerInfo.peerId
  notice "Started dagger node", id = $node.networkId, addrs = node.switch.peerInfo.addrs

proc stop*(node: DaggerNodeRef) {.async.} =
  trace "Stopping node"

  if not node.engine.isNil:
    await node.engine.stop()

  if not node.switch.isNil:
    await node.switch.stop()

  if not node.erasure.isNil:
    await node.erasure.stop()

proc findPeer*(
  node: DaggerNodeRef,
  peerId: PeerID): Future[?!PeerRecord] {.async.} =
  discard

proc connect*(
  node: DaggerNodeRef,
  peerId: PeerID,
  addrs: seq[MultiAddress]): Future[void] =
  node.switch.connect(peerId, addrs)

proc retrieve*(
  node: DaggerNodeRef,
  cid: Cid): Future[?!LPStream] {.async.} =

  trace "Received retrieval request", cid
  without blk =? await node.blockStore.getBlock(cid):
    return failure(
      newException(DaggerError, "Couldn't retrieve block for Cid!"))

  without mc =? blk.cid.contentType():
    return failure(
      newException(DaggerError, "Couldn't identify Cid!"))

  # if we got a manifest, stream the blocks
  if $mc in ManifestContainers:
    trace "Retrieving data set", cid, mc

    without manifest =? Manifest.decode(blk.data, ManifestContainers[$mc]):
      return failure("Unable to construct manifest!")

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
  node: DaggerNodeRef,
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
      if not (await node.blockStore.putBlock(blk)):
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
      newException(DaggerError, "Could not generate dataset manifest!"))

  # Store as a dag-pb block
  without manifest =? bt.Block.new(data = data, codec = DagPBCodec):
    trace "Unable to init block from manifest data!"
    return failure("Unable to init block from manifest data!")

  if not (await node.blockStore.putBlock(manifest)):
    trace "Unable to store manifest", cid = manifest.cid
    return failure("Unable to store manifest " & $manifest.cid)

  without cid =? blockManifest.cid, error:
    trace "Unable to generate manifest Cid!", exc = error.msg
    return failure(error.msg)

  trace "Stored data", manifestCid = manifest.cid,
                       contentCid = cid,
                       blocks = blockManifest.len

  return manifest.cid.success

proc requestStorage*(
  self: DaggerNodeRef,
  cid: Cid,
  ppb: uint,
  duration: Duration,
  nodeCount: uint,
  tolerance: uint,
  autoRenew: bool = false): Future[?!Cid] {.async.} =
  trace "Received a request for storage!", cid, ppb, duration, nodeCount, tolerance, autoRenew
  return cid.success

proc new*(
  T: type DaggerNodeRef,
  switch: Switch,
  store: BlockStore,
  engine: BlockExcEngine,
  erasure: Erasure): T =
  T(
    switch: switch,
    blockStore: store,
    engine: engine,
    erasure: erasure)
