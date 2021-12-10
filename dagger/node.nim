## Nim-Dagger
## Copyright (c) 2021 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import std/options
import std/sequtils

import pkg/questionable
import pkg/questionable/results
import pkg/chronicles
import pkg/chronos
import pkg/libp2p
import pkg/stew/byteutils

# TODO: remove once exported by libp2p
import pkg/libp2p/routing_record
import pkg/libp2p/signed_envelope

import ./conf
import ./chunker
import ./blocktype as bt
import ./blockset
import ./utils/asyncfutures
import ./stores/blockstore
import ./blockexchange

const
  FileChunkSize* = 4096 # file chunk read size

type
  DaggerError = object of CatchableError

  DaggerNodeRef* = ref object
    switch*: Switch
    config*: DaggerConf
    networkId*: PeerID
    blockStore*: BlockStore
    engine*: BlockExcEngine

proc start*(node: DaggerNodeRef) {.async.} =
  discard await node.switch.start()
  await node.engine.start()
  node.networkId = node.switch.peerInfo.peerId
  trace "Started dagger node", id = node.networkId, addrs = node.switch.peerInfo.addrs

proc stop*(node: DaggerNodeRef) {.async.} =
  await node.engine.stop()
  await node.switch.stop()

proc findPeer*(
  node: DaggerNodeRef,
  peerId: PeerID): Future[?!PeerRecord] {.async.} =
  discard

proc connect*(
  node: DaggerNodeRef,
  peerId: PeerID,
  addrs: seq[MultiAddress]): Future[void] =
  node.switch.connect(peerId, addrs)

proc streamBlocks*(
  node: DaggerNodeRef,
  stream: BufferStream,
  blockRequests: seq[Future[?bt.Block]]) {.async.} =

  try:
    var
      blockRequests = blockRequests # copy to be able to modify

    while true:
      if blockRequests.len <= 0:
        break

      let retrievedFut = await one(blockRequests)
      blockRequests.keepItIf(
        it != retrievedFut
      )

      if retrieved =? (await retrievedFut):
        await stream.pushData(retrieved.data)
  except CatchableError as exc:
    trace "Exception retrieving blocks", exc = exc.msg
  finally:
    await stream.pushEof()
    await stream.close()

proc retrieve*(
  node: DaggerNodeRef,
  cid: Cid): Future[?!LPStream] {.async.} =

  trace "Received retrieval request", cid
  let
    blkRes = await node.blockStore.getBlock(cid)
    stream = BufferStream.new()
    streamRes = LPStream(stream).success

  without blk =? blkRes:
    return failure(
      newException(DaggerError, "Couldn't retrieve block for Cid!"))

  without mc =? blk.cid.contentType():
    return failure(
      newException(DaggerError, "Couldn't identify Cid!"))

  if mc == MultiCodec.codec("dag-pb"):
    trace "Retrieving data set", cid, mc
    let
      blockSet = BlockSetRef.new(blk)

    var
      blockRequests = blockSet.blocks.mapIt(
        node.blockStore.getBlock(it)
      )

    asyncSpawn node.streamBlocks(stream, blockRequests)
  else:
    asyncSpawn (proc(): Future[void] {.async.} =
      try:
        await stream.pushData(blk.data)
      except CatchableError as exc:
        trace "Unable to send block", cid
      finally:
        await stream.pushEof()
        await stream.close())()

  return streamRes

proc store*(
  node: DaggerNodeRef,
  stream: LPStream): Future[?!Cid] {.async.} =
  trace "Storing data"

  let
    blockSet = BlockSetRef.new()
    blocks = LPStreamChunker
    .new(stream)
    .toStream()
    .toStream()
    .toStream(blockSet)

  for b in blocks:
    await node.blockStore.putBlock((await b))

  # Generate manifest
  without data =? BlockSetRef.encode(blockSet):
    return failure(
      newException(DaggerError, "Could not generate dataset manifest!"))

  # Store as a dag-pb block
  let manifest = bt.Block.new(data = data, codec = ManifestCodec)
  await node.blockStore.putBlock(manifest)

  trace "Stored data", cid = manifest.cid

  return manifest.cid.success

proc new*(
  T: type DaggerNodeRef,
  switch: Switch,
  store: BlockStore,
  engine: BlockExcEngine,
  config: DaggerConf): T =
  T(
    switch: switch,
    config: config,
    blockStore: store,
    engine: engine)
