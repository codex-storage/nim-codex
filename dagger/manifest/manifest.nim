## Nim-Dagger
## Copyright (c) 2022 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

{.push raises: [Defect].}

import std/tables
import pkg/libp2p/protobuf/minprotobuf
import pkg/libp2p
import pkg/questionable
import pkg/questionable/results
import pkg/chronicles

import ./types
import ./coders
import ../errors
import ../blocktype

export coders, Manifest

const
  ManifestContainers* = {
    $DagPBCodec: DagPBCoder()
  }.toTable

func len*(self: Manifest): int =
  self.blocks.len

func size*(self: Manifest): int =
  self.blocks.len * self.blockSize

func `[]`*(self: Manifest, i: Natural): Cid =
  self.blocks[i]

func `[]=`*(self: var Manifest, i: Natural, item: Cid) =
  self.rootHash = Cid.none
  self.blocks[i] = item

func `[]`*(self: Manifest, i: BackwardsIndex): Cid =
  self.blocks[self.len - i.int]

func `[]=`*(self: var Manifest, i: BackwardsIndex, item: Cid) =
  self.rootHash = Cid.none
  self.blocks[self.len - i.int] = item

proc add*(self: var Manifest, cid: Cid) =
  self.rootHash = Cid.none
  trace "Adding cid to manifest", cid
  self.blocks.add(cid)

iterator items*(self: Manifest): Cid =
  for b in self.blocks:
    yield b

func contains*(self: Manifest, cid: Cid): bool =
  cid in self.blocks

template hashBytes(mh: MultiHash): seq[byte] =
  ## get the hash bytes of a multihash object
  ##

  mh.data.buffer[mh.dpos..(mh.dpos + mh.size - 1)]

proc makeRoot(self: var Manifest): ?!void =
  ## Create a tree hash root of the contained
  ## block hashes
  ##

  var
    stack: seq[MultiHash]

  for cid in self:
    stack.add(? cid.mhash.mapFailure)

    while stack.len > 1:
      let
        (b1, b2) = (stack.pop(), stack.pop())
        mh = ? MultiHash.digest(
          $self.hcodec,
          (b1.hashBytes() & b2.hashBytes()))
          .mapFailure
      stack.add(mh)

  if stack.len == 1:
    let cid = ? Cid.init(
      self.version,
      self.codec,
      (? EmptyDigests[self.version][self.hcodec].catch))
      .mapFailure

    self.rootHash = cid.some

  ok()

proc cid*(self: var Manifest): ?!Cid =
  ## Generate a root hash using the treehash algorithm
  ##

  if self.rootHash.isNone:
    ? self.makeRoot()

  (!self.rootHash).success

proc encode*(self: var Manifest, encoder = ManifestContainers[$DagPBCodec]): ?!seq[byte] =
  ## Encode a manifest using `encoder`
  ##

  if self.rootHash.isNone:
    ? self.makeRoot()

  encoder.encode(self)

func decode*(
  _: type Manifest,
  data: openArray[byte],
  decoder = ManifestContainers[$DagPBCodec]): ?!Manifest =
  ## Decode a manifest using `decoder`
  ##

  decoder.decode(data)

proc init*(
  T: type Manifest,
  blocks: openArray[Cid] = [],
  version = CIDv1,
  hcodec = multiCodec("sha2-256"),
  codec = multiCodec("raw"),
  blockSize = BlockSize): ?!T =
  ## Create a manifest using array of `Cid`s
  ##

  if hcodec notin EmptyDigests[version]:
    return failure("Unsupported manifest hash codec!")

  T(
    blocks: @blocks,
    version: version,
    codec: codec,
    hcodec: hcodec,
    blockSize: blockSize
    ).success
