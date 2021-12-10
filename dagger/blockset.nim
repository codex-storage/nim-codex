## Nim-Dagger
## Copyright (c) 2021 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

{.push raises: [Defect].}

import pkg/libp2p
import pkg/libp2p/protobuf/minprotobuf
import pkg/questionable
import pkg/questionable/results
import pkg/chronicles
import pkg/chronos

import ./blocktype
import ./utils/asyncfutures

const
  ManifestCodec* = multiCodec("dag-pb")

type
  BlockSetRef* = ref object
    blocks*: seq[Cid]
    version*: CidVersion
    hcodec*: MultiCodec
    codec*: MultiCodec

proc hashBytes(mh: MultiHash): seq[byte] =
  mh.data.buffer[mh.dpos..(mh.dpos + mh.size - 1)]

proc treeHash*(b: BlockSetRef): ?Cid =
  var
    stack: seq[MultiHash]

  for cid in b.blocks:
    if mhash =? cid.mhash:
      stack.add(mhash)

    while stack.len > 1:
      let
        (b1, b2) = (stack.pop(), stack.pop())
        digest = MultiHash.digest(
          $b.hcodec,
          (b1.hashBytes() & b2.hashBytes()))

      without mh =? digest:
        return Cid.none

      stack.add(mh)

  if stack.len == 1:
    let
      cid = Cid.init(b.version, b.codec, stack[0])

    if cid.isOk:
      return cid.get().some

proc encode*(_: type BlockSetRef, b: BlockSetRef): ?!seq[byte] =
  var pbNode = initProtoBuffer()

  for cid in b.blocks:
    var pbLink = initProtoBuffer()
    pbLink.write(1, cid.data.buffer) # write hash
    pbLink.finish()
    pbNode.write(2, pbLink)

  without cid =? b.treeHash():
    return failure(
      newException(DaggerError, "Unable to generate tree hash"))

  pbNode.write(1, cid.data.buffer)

  pbNode.finish()
  return pbNode.buffer.success

proc decode*(_: type BlockSetRef, data: seq[byte]): ?!(Cid, seq[Cid]) =
  var pbNode = initProtoBuffer(data)
  var
    cidBuf: seq[byte]
    blocks: seq[Cid]

  if pbNode.getField(1, cidBuf).isOk:
    if cid =? Cid.init(cidBuf):
      var linksBuf: seq[seq[byte]]
      if pbNode.getRepeatedField(2, linksBuf).isOk:
        for pbLinkBuf in linksBuf:
          var
            blocksBuf: seq[seq[byte]]
            blockBuf: seq[byte]
            pbLink = initProtoBuffer(pbLinkBuf)

          if pbLink.getField(1, blockBuf).isOk:
            let cidRes = Cid.init(blockBuf)
            if cidRes.isOk:
              blocks.add(cidRes.get())

      return (cid, blocks).success

func new*(
  T: type BlockSetRef,
  blocks: openArray[Cid] = [],
  version = CIDv1,
  hcodec = multiCodec("sha2-256"),
  codec = multiCodec("raw")): T =
  T(
    blocks: @blocks,
    version: version,
    codec: codec,
    hcodec: hcodec)

func new*(
  T: type BlockSetRef,
  blk: Block): T =

  let res = BlockSetRef.decode(blk.data)
  if res.isOk:
    let
      (cid, blocks) = res.get()
    # TODO: check that the treeHash and cid match!
    return T(blocks: blocks)

proc toStream*(
  blocks: AsyncFutureStream[Block],
  blockSet: BlockSetRef): AsyncFutureStream[Block] =
  let
    stream = AsyncPushable[Block].new()

  proc pusher() {.async, nimcall, raises: [Defect].} =
    try:
      for blockFut in blocks:
        let
          blk = await blockFut

        blockSet.blocks.add(blk.cid)
        await stream.push(blk)
    except CatchableError as exc:
      trace "Unknown exception, raising Defect", exc = exc.msg
      raiseAssert exc.msg
    finally:
      stream.finish()

  asyncSpawn pusher()
  return stream
