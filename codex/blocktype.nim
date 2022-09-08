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

import pkg/libp2p
import pkg/stew/byteutils
import pkg/questionable
import pkg/questionable/results

import ./errors

const
  BlockSize* = 65536 # block size

type
  Block* = ref object of RootObj
    cid*: Cid
    data*: seq[byte]

  BlockNotFoundError* = object of CodexError

template EmptyCid*: untyped =
  var
    emptyCid {.global, threadvar.}:
      array[CIDv0..CIDv1, Table[MultiCodec, Cid]]

  once:
    emptyCid = [
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

  emptyCid

template EmptyDigests*: untyped =
  var
    emptyDigests {.global, threadvar.}:
      array[CIDv0..CIDv1, Table[MultiCodec, MultiHash]]

  once:
    emptyDigests = [
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

  emptyDigests

template EmptyBlock*: untyped =
  var
    emptyBlock {.global, threadvar.}:
      array[CIDv0..CIDv1, Table[MultiCodec, Block]]

  once:
    emptyBlock = [
      CIDv0: {
        multiCodec("sha2-256"): Block(
          cid: EmptyCid[CIDv0][multiCodec("sha2-256")])
      }.toTable,
      CIDv1: {
        multiCodec("sha2-256"): Block(
          cid: EmptyCid[CIDv1][multiCodec("sha2-256")])
      }.toTable,
    ]

  emptyBlock

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
    return "Cid and content don't match!".failure

  success b
