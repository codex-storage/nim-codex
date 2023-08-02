## Nim-Codex
## Copyright (c) 2021 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import std/tables
export tables

import pkg/upraises

push: {.upraises: [].}

import pkg/libp2p/[cid, multicodec, multihash]
import pkg/stew/byteutils
import pkg/questionable
import pkg/questionable/results
import pkg/chronicles

import ./units
import ./utils
import ./formats
import ./errors

export errors, formats, units

const
  # Size of blocks for storage / network exchange,
  # should be divisible by 31 for PoR and by 64 for Leopard ECC
  DefaultBlockSize* = NBytes 31 * 64 * 33

type
  Block* = ref object of RootObj
    cid*: Cid
    data*: seq[byte]

var
  EmptyCid {.threadvar.}: array[CIDv0..CIDv1, Table[MultiCodec, Cid]]

proc emptyCid*(version: CidVersion, codex: MultiCodec): ?!Cid =
  once:
    EmptyCid = [
      CIDv0: {
        multiCodec("sha2-256"): Cid
        .init("QmdfTbBqBPQ7VNxZEYEj14VmRuZBkqFbiwReogJgS1zR1n")
        .get()
      }.toTable,
      CIDv1: {
        multiCodec("sha2-256"): Cid
        .init("bafybeihdwdcefgh4dqkjv67uzcmw7ojee6xedzdetojuzjevtenxquvyku")
        .get()
      }.toTable,
    ]

  try:
    success EmptyCid[version][codex]
  except CatchableError as exc:
    err(exc)

var
  EmptyDigests {.threadvar.}: array[CIDv0..CIDv1, Table[MultiCodec, MultiHash]]

proc emptyDigest*(version: CidVersion, codex: MultiCodec): ?!MultiHash =
  once:
    EmptyDigests = [
        CIDv0: {
          multiCodec("sha2-256"): EmptyCid[CIDv0]
          .catch
          .get()[multiCodec("sha2-256")]
          .catch
          .get()
          .mhash
          .get()
        }.toTable,
        CIDv1: {
          multiCodec("sha2-256"): EmptyCid[CIDv1]
          .catch
          .get()[multiCodec("sha2-256")]
          .catch
          .get()
          .mhash
          .get()
        }.toTable,
      ]

  try:
    success EmptyDigests[version][codex]
  except CatchableError as exc:
    err(exc)

var
  EmptyBlock {.threadvar.}: array[CIDv0..CIDv1, Table[MultiCodec, Block]]

proc emptyBlock*(version: CidVersion, codex: MultiCodec): ?!Block =
  once:
    let cid = ? EmptyCid[CIDv0].catch
    let sha2 = ? cid[multiCodec("sha2-256")].catch
    let blk = Block(cid: sha2)

    EmptyBlock = [
      CIDv0: { multiCodec("sha2-256"): blk }.toTable,
      CIDv1: { multiCodec("sha2-256"): blk }.toTable,
    ]

  try:
    success EmptyBlock[version][codex]
  except CatchableError as exc:
    err(exc)


proc isEmpty*(cid: Cid): bool =
  cid == emptyCid(cid.cidver, cid.mhash.get().mcodec).get()

proc isEmpty*(blk: Block): bool =
  blk.cid.isEmpty

proc emptyBlock*(cid: Cid): Block =
  EmptyBlock[cid.cidver]
  .catch
  .get()[cid.mhash.get().mcodec]
  .catch
  .get()

proc `$`*(b: Block): string =
  result &= "cid: " & $b.cid
  result &= "\ndata: " & string.fromBytes(b.data)

func new*(
    T: type Block,
    data: openArray[byte] = [],
    version = CIDv1,
    mcodec = multiCodec("sha2-256"),
    codec = multiCodec("raw")
): ?!Block =
  ## creates a new block for both storage and network IO
  ## 

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
    verify: bool = true
): ?!Block =
  ## creates a new block for both storage and network IO
  ## 

  let
    mhash = ? cid.mhash.mapFailure
    b = ? Block.new(
      data = @data,
      version = cid.cidver,
      codec = cid.mcodec,
      mcodec = mhash.mcodec)

  if verify and cid != b.cid:
    return "Cid and content don't match!".failure

  success b
