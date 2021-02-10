## Nim-Dagger
## Copyright (c) 2021 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import pkg/libp2p/multihash
import pkg/libp2p/multicodec
import pkg/libp2p/cid
import pkg/stew/byteutils

export cid, multihash, multicodec

type
  CidDontMatchError* = object of CatchableError

  Block* = object of RootObj
    cid*: Cid
    data*: seq[byte]

proc `$`*(b: Block): string =
  result &= "cid: " & $b.cid
  result &= "\ndata: " & string.fromBytes(b.data)

proc new*(
  T: type Block,
  cid: Cid,
  data: openarray[byte],
  verify: bool = false): T =
  let b = Block.new(
    data,
    cid.cidver,
    cid.mhash.get().mcodec,
    cid.mcodec
  )

  if verify and cid != b.cid:
    raise newException(CidDontMatchError,
      "The suplied Cid doesn't match the data!")

  return b

proc new*(
  T: type Block,
  data: openarray[byte] = [],
  version = CIDv0,
  hcodec = multiCodec("sha2-256"),
  codec = multiCodec("dag-pb")): T =
  let hash =  MultiHash.digest($hcodec, data).get()
  Block(
    cid: Cid.init(version, codec, hash).get(),
    data: @data)
