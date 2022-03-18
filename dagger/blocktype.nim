## Nim-Dagger
## Copyright (c) 2021 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import pkg/upraises

push: {.upraises: [].}

import pkg/libp2p
import pkg/stew/byteutils
import pkg/questionable
import pkg/questionable/results

import ./errors

const
  BlockSize* = 4096 # file chunk read size

type
  Block* = ref object of RootObj
    cid*: Cid
    data*: seq[byte]

proc `$`*(b: Block): string =
  result &= "cid: " & $b.cid
  result &= "\ndata: " & string.fromBytes(b.data)

func new*(
  T: type Block,
  data: openArray[byte] = [],
  version = CIDv1,
  mcodec = multiCodec("sha2-256"),
  codec = multiCodec("raw")): ?!T =

  let
    hash = ? MultiHash.digest($mcodec, data).mapFailure
    cid = ? Cid.init(version, codec, hash).mapFailure

  # TODO: If the hash is `>=` to the data,
  # use the Cid as a container!
  Block(
    cid: cid,
    data: @data).success

func new*(
  T: type Block,
  cid: Cid,
  data: openArray[byte],
  verify: bool = true): ?!T =

  let
    mhash = ? cid.mhash.mapFailure
    b = ? Block.new(
      data = @data,
      version = cid.cidver,
      codec = cid.mcodec,
      mcodec = mhash.mcodec)

  if verify and cid != b.cid:
    return "Cid's don't match!".failure

  success b
