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
import pkg/chronos
import pkg/chronicles
import pkg/questionable
import pkg/questionable/results
import pkg/stew/byteutils

import ./utils/asyncfutures

type
  Block* = object of RootObj
    cid*: Cid
    data*: seq[byte]

proc `$`*(b: Block): string =
  result &= "cid: " & $b.cid
  result &= "\ndata: " & string.fromBytes(b.data)

func new*(
  T: type Block,
  data: openArray[byte] = [],
  version = CIDv1,
  hcodec = multiCodec("sha2-256"),
  codec = multiCodec("raw")): T =
  let hash =  MultiHash.digest($hcodec, data).get()
  Block(
    cid: Cid.init(version, codec, hash).get(),
    data: @data)

func new*(
  T: type Block,
  cid: Cid,
  data: openArray[byte] = [],
  verify: bool = false): T =
  Block.new(
    data,
    cid.cidver,
    cid.mhash.get().mcodec,
    cid.mcodec
  )

proc toStream*(
  bytes: AsyncFutureStream[seq[byte]]):
  AsyncFutureStream[Block] =

  let
    stream = AsyncPushable[Block].new()

  proc pusher() {.async, nimcall, raises: [Defect].} =
    try:
      for bytesFut in bytes:
        let
          blk = Block.new((await bytesFut))

        await stream.push(blk)
    except CatchableError as exc:
      trace "Unknown exception, raising Defect", exc = exc.msg
      raiseAssert exc.msg
    finally:
      stream.finish()

  asyncSpawn pusher()
  return stream
