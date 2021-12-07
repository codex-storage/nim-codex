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
import pkg/questionable
import pkg/questionable/results
import pkg/chronicles
import pkg/chronos

import ./blocktype
import ./utils/asyncfutures

const
  HCodec* = multiCodec("sha2-256")
  Codec* = multiCodec("dag-pb")

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

proc encode*(b: BlockSetRef): seq[byte] =
  discard

proc decode*(b: BlockSetRef, data: var openArray[byte]) =
  discard

func new*(
  T: type BlockSetRef,
  version = CIDv1,
  hcodec = HCodec,
  codec = Codec): T =
  T(
    version: version,
    codec: codec,
    hcodec: hcodec)

proc toStream*(
  blocks: AsyncFutureStream[?Block],
  blockSet: BlockSetRef): AsyncFutureStream[?Block] =
  let
    stream = AsyncPushable[?Block].new()

  proc pusher() {.async, nimcall, raises: [Defect].} =
    try:
      for blockFut in blocks:
        let
          blk = await blockFut

        if blk.isSome:
          blockSet.blocks.add((!blk).cid)

        await stream.push(blk)
    except AsyncFutureStreamError as exc:
      trace "Exception pushing to futures stream", exc = exc.msg
    except CatchableError as exc:
      trace "Unknown exception, raising defect", exc = exc.msg
      raiseAssert exc.msg
    finally:
      stream.finish()

  asyncSpawn pusher()
  return stream
