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

template EmptyCid*: untyped =
  var
    EmptyCid {.global, threadvar.}:
      array[CIDv0..CIDv1, Table[MultiCodec, Cid]]

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

  EmptyCid

template EmptyDigests*: untyped =
  var
    EmptyDigests {.global, threadvar.}:
      array[CIDv0..CIDv1, Table[MultiCodec, MultiHash]]

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

  EmptyDigests

template EmptyBlock*: untyped =
  var
    EmptyBlock {.global, threadvar.}:
      array[CIDv0..CIDv1, Table[MultiCodec, Block]]

  once:
    EmptyBlock = [
      CIDv0: {
        multiCodec("sha2-256"): Block(
          cid: EmptyCid[CIDv0][multiCodec("sha2-256")])
      }.toTable,
      CIDv1: {
        multiCodec("sha2-256"): Block(
          cid: EmptyCid[CIDv1][multiCodec("sha2-256")])
      }.toTable,
    ]

  EmptyBlock

proc isEmpty*(cid: Cid): bool =
  cid == EmptyCid[cid.cidver]
  .catch
  .get()[cid.mhash.get().mcodec]
  .catch
  .get()

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

proc new*(
    T: type Block,
    cid: Cid,
    data: openArray[byte],
    verify: bool = true
): ?!Block =
  ## creates a new block for both storage and network IO
  ##

  if verify:
    let
      mhash = ? cid.mhash.mapFailure
      computedMhash = ? MultiHash.digest($mhash.mcodec, data).mapFailure
      computedCid = ? Cid.init(cid.cidver, cid.mcodec, computedMhash).mapFailure
    if computedCid != cid:
      return "Cid doesn't match the data".failure

  return Block(
    cid: cid,
    data: @data
  ).success

