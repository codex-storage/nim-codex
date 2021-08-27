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
import pkg/stew/byteutils

type
  Block* = object of RootObj
    cid*: Cid
    data*: seq[byte]

proc `$`*(b: Block): string =
  result &= "cid: " & $b.cid
  result &= "\ndata: " & string.fromBytes(b.data)

proc new*(
  T: type Block,
  data: openArray[byte] = [],
  version = CIDv1,
  hcodec = multiCodec("sha2-256"),
  codec = multiCodec("raw")): ?!T =
  let hash =  MultiHash.digest($hcodec, data).get()
  success Block(
    cid: Cid.init(version, codec, hash).get(),
    data: @data)

proc new*(
  T: type Block,
  cid: Cid,
  data: openArray[byte] = [],
  verify: bool = false): ?!T =
  let res = Block.new(
    data,
    cid.cidver,
    cid.mhash.get().mcodec,
    cid.mcodec
  )

  if b =? res:
    if verify and cid != b.cid:
      return failure("The suplied Cid doesn't match the data!")

  res
