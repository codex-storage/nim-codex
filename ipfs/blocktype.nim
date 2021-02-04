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

export cid, multihash, multicodec

type
  Block* = object
    cid*: Cid
    data*: seq[byte]

proc new*(
  T: type Block,
  data: openarray[byte],
  version = CIDv0,
  hash = "sha2-256",
  multicodec = "dag-pb"): T =
  let codec = multiCodec("dag-pb")
  let hash =  MultiHash.digest("sha2-256", data).get()
  return Block(cid: Cid.init(version, multicodec, hash).get(), data: data)
