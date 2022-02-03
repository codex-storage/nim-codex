## Nim-Dagger
## Copyright (c) 2021 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import std/options

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
import ./blocksmanifest
import ./stores/manager
import ./blockexchange

logScope:
  topics = "dagger node"

const
  FileChunkSize* = 4096 # file chunk read size

type
  DaggerError = object of CatchableError

  DaggerNodeRef* = ref object
    switch*: Switch
    networkId*: PeerID
    engine*: BlockExcEngine

proc start*(node: DaggerNodeRef) {.async.} =
  await node.switch.start()
  await node.engine.start()
  node.networkId = node.switch.peerInfo.peerId
  notice "Started dagger node", id = $node.networkId, addrs = node.switch.peerInfo.addrs

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
  blockManifest: BlocksManifest) {.async.} =

  try:
    # TODO: Read sequentially for now
    # to prevent slurping the entire dataset
    # since disk IO is blocking
    for c in blockManifest:
      without blk =? (await node.engine.retrieve(c)):
        warn "Couldn't retrieve block", cid = c
        break # abort if we couldn't get a block

      trace "Streaming block data", cid = blk.cid, bytes = blk.data.len
      await stream.pushData(blk.data)
  except CatchableError as exc:
    trace "Exception retrieving blocks", exc = exc.msg
  finally:
    await stream.pushEof()

proc retrieve*(
  node: DaggerNodeRef,
  stream: BufferStream,
  cid: Cid): Future[?!void] {.async.} =

  trace "Received retrieval request", cid
  without blk =? await node.engine.retrieve(cid):
    return failure(
      newException(DaggerError, "Couldn't retrieve block for Cid!"))

  without mc =? blk.cid.contentType():
    return failure(
      newException(DaggerError, "Couldn't identify Cid!"))

  if mc == ManifestCodec:
    trace "Retrieving data set", cid, mc

    without blockManifest =? BlocksManifest.init(blk.data):
      return failure("Unable to construct manifest!")

    asyncSpawn node.streamBlocks(stream, blockManifest)
  else:
    asyncSpawn (proc(): Future[void] {.async.} =
      try:
        await stream.pushData(blk.data)
      except CatchableError as exc:
        trace "Unable to send block", cid
        discard
      finally:
        await stream.pushEof())()

  return success()

proc store*(
  node: DaggerNodeRef,
  stream: LPStream): Future[?!Cid] {.async.} =
  trace "Storing data"

  without var blockManifest =? BlocksManifest.init():
    return failure("Unable to create Block Set")

  let
    chunker = LPStreamChunker.new(stream)

  try:
    while (
      let chunk = await chunker.getBytes();
      chunk.len > 0):

      trace "Got data from stream", len = chunk.len
      without blk =? bt.Block.init(chunk):
        return failure("Unable to init block from chunk!")

      blockManifest.put(blk.cid)
      if not (await node.engine.store(blk)):
        # trace "Unable to store block", cid = blk.cid
        return failure("Unable to store block " & $blk.cid)
      node.engine.resolveBlocks(@[blk])

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
  without manifest =? bt.Block.init(data = data, codec = ManifestCodec):
    trace "Unable to init block from manifest data!"
    return failure("Unable to init block from manifest data!")

  if not (await node.engine.store(manifest)):
    trace "Unable to store manifest", cid = manifest.cid
    return failure("Unable to store manifest " & $manifest.cid)
  node.engine.resolveBlocks(@[manifest])

  var cid: ?!Cid
  if (cid = blockManifest.cid; cid.isErr):
    trace "Unable to generate manifest Cid!", exc = cid.error.msg
    return failure(cid.error.msg)

  trace "Stored data", manifestCid = manifest.cid,
                       contentCid = !cid,
                       blocks = blockManifest.len

  return manifest.cid.success

proc new*(
  T: type DaggerNodeRef,
  switch: Switch,
  engine: BlockExcEngine): T =
  T(
    switch: switch,
    engine: engine)
