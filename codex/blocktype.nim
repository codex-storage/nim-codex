## Nim-Codex
## Copyright (c) 2021 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import std/tables
import std/sugar
export tables

import pkg/upraises

push: {.upraises: [].}

import pkg/libp2p/[cid, multicodec, multihash]
import pkg/stew/byteutils
import pkg/questionable
import pkg/questionable/results
import pkg/chronicles
import pkg/json_serialization

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

  BlockAddress* = object
    case leaf*: bool
    of true:
      treeCid*: Cid
      index*: Natural
    else:
      cid*: Cid


proc `==`*(a, b: BlockAddress): bool =
  a.leaf == b.leaf and
    (
      if a.leaf:
        a.treeCid == b.treeCid and a.index == b.index
      else:
        a.cid == b.cid
    )

proc `$`*(a: BlockAddress): string =
  if a.leaf:
    "treeCid: " & $a.treeCid & ", index: " & $a.index
  else:
    "cid: " & $a.cid

proc writeValue*(
  writer: var JsonWriter,
  value: Cid
) {.upraises:[IOError].} =
  writer.writeValue($value)

proc cidOrTreeCid*(a: BlockAddress): Cid =
  if a.leaf:
    a.treeCid
  else:
    a.cid

proc address*(b: Block): BlockAddress =
  BlockAddress(leaf: false, cid: b.cid)

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

proc emptyCid*(version: CidVersion, hcodec: MultiCodec, dcodec: MultiCodec): ?!Cid =
  ## Returns cid representing empty content, given cid version, hash codec and data codec
  ## 

  const
    Sha256 = multiCodec("sha2-256")
    Raw = multiCodec("raw")
    DagPB = multiCodec("dag-pb")
    DagJson = multiCodec("dag-json")

  var index {.global, threadvar.}: Table[(CIDv0, Sha256, DagPB), Result[Cid, CidError]]
  once:
    index = {
        # source https://ipld.io/specs/codecs/dag-pb/fixtures/cross-codec/#dagpb_empty
        (CIDv0, Sha256, DagPB): Cid.init("QmdfTbBqBPQ7VNxZEYEj14VmRuZBkqFbiwReogJgS1zR1n"),
        (CIDv1, Sha256, DagPB): Cid.init("zdj7Wkkhxcu2rsiN6GUyHCLsSLL47kdUNfjbFqBUUhMFTZKBi"), # base36: bafybeihdwdcefgh4dqkjv67uzcmw7ojee6xedzdetojuzjevtenxquvyku
        (CIDv1, Sha256, DagJson): Cid.init("z4EBG9jGUWMVxX9deANWX7iPyExLswe2akyF7xkNAaYgugvnhmP"), # base36: baguqeera6mfu3g6n722vx7dbitpnbiyqnwah4ddy4b5c3rwzxc5pntqcupta
        (CIDv1, Sha256, Raw): Cid.init("zb2rhmy65F3REf8SZp7De11gxtECBGgUKaLdiDj7MCGCHxbDW"),
      }.toTable

  index[(version, hcodec, dcodec)].catch.flatMap((a: Result[Cid, CidError]) => a.mapFailure)

proc emptyDigest*(version: CidVersion, hcodec: MultiCodec, dcodec: MultiCodec): ?!MultiHash =
  emptyCid(version, hcodec, dcodec)
    .flatMap((cid: Cid) => cid.mhash.mapFailure)

proc emptyBlock*(version: CidVersion, hcodec: MultiCodec): ?!Block =
  emptyCid(version, hcodec, multiCodec("raw"))
    .flatMap((cid: Cid) => Block.new(cid = cid, data = @[]))

proc emptyBlock*(cid: Cid): ?!Block =
  cid.mhash.mapFailure.flatMap((mhash: MultiHash) => 
      emptyBlock(cid.cidver, mhash.mcodec))

proc isEmpty*(cid: Cid): bool =
  success(cid) == cid.mhash.mapFailure.flatMap((mhash: MultiHash) => 
      emptyCid(cid.cidver, mhash.mcodec, cid.mcodec))

proc isEmpty*(blk: Block): bool =
  blk.cid.isEmpty
