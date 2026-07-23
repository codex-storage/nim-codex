## Logos Storage
## Copyright (c) 2021 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import std/[tables, sugar, hashes]

{.push raises: [], gcsafe.}

import pkg/libp2p/[cid, multicodec, multihash]
import pkg/protobuf_serialization
import pkg/stew/[byteutils, endians2]
import pkg/questionable
import pkg/questionable/results

import ./units
import ./utils
import ./errors
import ./logutils
import ./utils/json
import ./storagetypes

export errors, logutils, units, storagetypes

type
  Block* = ref object of RootObj
    cid*: Cid
    data*: ref seq[byte]

  BlockAddress* {.proto2.} = object
    treeCid* {.serialize, fieldNumber: 1, required, ext.}: Cid
    index* {.serialize, fieldNumber: 2, required, pint.}: uint64

logutils.formatIt(LogFormat.textLines, BlockAddress):
  "treeCid: " & shortLog($it.treeCid) & ", index: " & $it.index

logutils.formatIt(LogFormat.json, BlockAddress):
  %it

proc `==`*(a, b: BlockAddress): bool =
  a.treeCid == b.treeCid and a.index == b.index

proc `$`*(a: BlockAddress): string =
  "treeCid: " & $a.treeCid & ", index: " & $a.index

proc hash*(a: BlockAddress): Hash =
  let data = a.treeCid.data.buffer & @(a.index.uint64.toBytesBE)
  hash(data)

proc init*(_: type BlockAddress, treeCid: Cid, index: uint64): BlockAddress =
  BlockAddress(treeCid: treeCid, index: index)

proc `$`*(b: Block): string =
  result &= "cid: " & $b.cid
  result &= "\ndata: " & string.fromBytes(b.data[])

func new*(
    T: type Block,
    data: openArray[byte] = [],
    version = CIDv1,
    mcodec = Sha256HashCodec,
    codec = BlockCodec,
): ?!Block =
  ## creates a new block for both storage and network IO

  let
    hash = ?MultiHash.digest($mcodec, data).mapFailure
    cid = ?Cid.init(version, codec, hash).mapFailure

  # TODO: If the hash is `>=` to the data,
  # use the Cid as a container!

  var dataRef: ref seq[byte]
  new(dataRef)
  dataRef[] = @data
  Block(cid: cid, data: dataRef).success

proc new*(T: type Block, cid: Cid, data: sink seq[byte], verify: bool = true): ?!Block =
  ## creates a new block for both storage and network IO
  ## takes ownership of the data seq to avoid copying

  if verify:
    let
      mhash = ?cid.mhash.mapFailure
      computedMhash = ?MultiHash.digest($mhash.mcodec, data).mapFailure
      computedCid = ?Cid.init(cid.cidver, cid.mcodec, computedMhash).mapFailure
    if computedCid != cid:
      return "Cid doesn't match the data".failure

  var dataRef: ref seq[byte]
  new(dataRef)
  dataRef[] = move(data)
  return Block(cid: cid, data: dataRef).success

proc new*(
    T: type Block, cid: Cid, data: openArray[byte], verify: bool = true
): ?!Block =
  ## creates a new block for both storage and network IO
  Block.new(cid, @data, verify)

proc emptyBlock*(version: CidVersion, hcodec: MultiCodec): ?!Block =
  emptyCid(version, hcodec, BlockCodec).flatMap(
    (cid: Cid) => Block.new(cid = cid, data = @[])
  )

proc emptyBlock*(cid: Cid): ?!Block =
  cid.mhash.mapFailure.flatMap(
    (mhash: MultiHash) => emptyBlock(cid.cidver, mhash.mcodec)
  )

proc isEmpty*(cid: Cid): bool =
  success(cid) ==
    cid.mhash.mapFailure.flatMap(
      (mhash: MultiHash) => emptyCid(cid.cidver, mhash.mcodec, cid.mcodec)
    )

proc isEmpty*(blk: Block): bool =
  blk.cid.isEmpty
