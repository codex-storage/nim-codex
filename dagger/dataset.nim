## Nim-Dagger
## Copyright (c) 2021 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

{.push raises: [Defect].}

import std/sequtils

import pkg/libp2p
import pkg/stew/byteutils
import pkg/questionable
import pkg/questionable/results

import ./blockstream

type
  BlockSetRef* = ref object of BlockStreamRef
    stream*: BlockStreamRef

proc hashBytes*(mh: MultiHash): seq[byte] =
  mh.data.buffer[mh.dpos..(mh.dpos + mh.size - 1)]

proc hashBytes*(b: Block): seq[byte] =
  without mh =? b.cid.mhash:
    return

  mh.hashBytes()

method nextBlock*(d: BlockSetRef): ?!Block =
  d.stream.nextBlock()

proc treeHash*(d: BlockSetRef): ?!MultiHash =
  var
    stack: seq[seq[byte]]
    codec: MultiCodec = InvalidMultiCodec

  while true:
    let (blk1, blk2) = (d.nextBlock().option, d.nextBlock().option)
    if blk1.isNone and blk2.isNone and stack.len == 1:
      let res = MultiHash.init($codec, stack[0])
      if mh =? res:
        return success mh

      return failure($res.error)

    if blk1.isSome: stack.add((!blk1).hashBytes())
    if blk2.isSome: stack.add((!blk2).hashBytes())

    codec = if codec == InvalidMultiCodec: (!blk1).cid.mcodec else: codec
    while (stack.len mod 2) == 0:
      let (b1, b2) = (stack.pop(), stack.pop())
      let res = MultiHash.init($codec, b1 & b2)
      if mh =? res:
        stack.add(mh.hashBytes())
      else:
        return failure($res.error)

proc new*(T: type BlockSetRef, blockStream: BlockStreamref) =
  discard
