## Nim-Dagger
## Copyright (c) 2021 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

{.push raises: [Defect].}

import std/tables

import pkg/libp2p
import pkg/questionable
import pkg/questionable/results
import pkg/chronicles
import pkg/chronos

import ./manifest
import ./errors

export manifest

const
  ManifestCodec* = multiCodec("dag-pb")

var
  emptyDigests {.threadvar.}: array[CIDv0..CIDv1, Table[MultiCodec, MultiHash]]
  once {.threadvar.}: bool

template EmptyDigests: untyped =
  if not once:
    emptyDigests = [
      CIDv0: {
        multiCodec("sha2-256"): Cid
        .init("bafybeihdwdcefgh4dqkjv67uzcmw7ojee6xedzdetojuzjevtenxquvyku")
        .get()
        .mhash
        .get()
      }.toTable,
      CIDv1: {
        multiCodec("sha2-256"): Cid.init("QmdfTbBqBPQ7VNxZEYEj14VmRuZBkqFbiwReogJgS1zR1n")
        .get()
        .mhash
        .get()
      }.toTable,
    ]

  once = true
  emptyDigests

type
  BlocksManifest* = object
    manifest: Manifest
    version*: CidVersion
    hcodec*: MultiCodec
    codec*: MultiCodec

proc len*(b: BlocksManifest): int = b.manifest.blocks.len

iterator items*(b: BlocksManifest): Cid =
  for b in b.manifest.blocks:
    yield b

template hashBytes(mh: MultiHash): seq[byte] =
  ## get the hash bytes of a multihash object
  ##

  mh.data.buffer[mh.dpos..(mh.dpos + mh.size - 1)]

proc cid*(b: var BlocksManifest): ?!Cid =
  ## Generate a root hash using the treehash algorithm
  ##

  if htree =? b.manifest.cid:
    return htree.success

  var
    stack: seq[MultiHash]

  for cid in b.manifest.blocks:
    stack.add(? cid.mhash.mapFailure)

    while stack.len > 1:
      let
        (b1, b2) = (stack.pop(), stack.pop())
        mh = ? MultiHash.digest(
          $b.hcodec,
          (b1.hashBytes() & b2.hashBytes()))
          .mapFailure
      stack.add(mh)

  if stack.len == 1:
    let cid = ? Cid.init(
      b.version,
      b.codec,
      (? EmptyDigests[b.version][b.hcodec].catch))
      .mapFailure

    b.manifest.cid = cid.some
    return cid.success

proc put*(b: var BlocksManifest, cid: Cid) =
  b.manifest.cid = Cid.none
  trace "Adding cid to manifest", cid
  b.manifest.blocks.add(cid)

proc contains*(b: BlocksManifest, cid: Cid): bool =
  cid in b.manifest.blocks

proc encode*(b: var BlocksManifest): ?!seq[byte] =
  if b.manifest.cid.isNone:
    b.manifest.cid = (? b.cid).some

  b.manifest.encode()

proc init*(
  T: type BlocksManifest,
  blocks: openArray[Cid] = [],
  version = CIDv1,
  hcodec = multiCodec("sha2-256"),
  codec = multiCodec("raw")): ?!T =
  ## Create a manifest using array of `Cid`s
  ##

  if hcodec notin EmptyDigests[version]:
    return failure("Unsupported manifest hash codec!")

  T(
    manifest: Manifest(blocks: @blocks),
    version: version,
    codec: codec,
    hcodec: hcodec,
    ).success

proc init*(
  T: type BlocksManifest,
  data: openArray[byte]): ?!T =
  ## Create manifest from a raw data blob
  ## (in dag-pb for for now)
  ##

  let
    manifest = ? Manifest.decode(data)
    cid = !manifest.cid
    mhash = ? cid.mhash.mapFailure

  var blockManifest = ? BlocksManifest.init(
    manifest.blocks,
    cid.version,
    mhash.mcodec,
    cid.mcodec)

  if cid != ? blockManifest.cid:
    return failure("Decoded content hash doesn't match!")

  blockManifest.success
