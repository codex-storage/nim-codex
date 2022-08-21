## Nim-Codex
## Copyright (c) 2022 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

# This module defines all operations on Manifest

import pkg/upraises

push: {.upraises: [].}

import pkg/libp2p/protobuf/minprotobuf
import pkg/libp2p
import pkg/questionable
import pkg/questionable/results
import pkg/chronicles

import ../errors
import ../utils
import ../blocktype
import ./types
import ./coders

############################################################
# Operations on block list
############################################################

func len*(self: Manifest): int =
  self.blocks.len

func `[]`*(self: Manifest, i: Natural): Cid =
  self.blocks[i]

func `[]=`*(self: var Manifest, i: Natural, item: Cid) =
  self.rootHash = Cid.none
  self.blocks[i] = item

func `[]`*(self: Manifest, i: BackwardsIndex): Cid =
  self.blocks[self.len - i.int]

func `[]=`*(self: Manifest, i: BackwardsIndex, item: Cid) =
  self.rootHash = Cid.none
  self.blocks[self.len - i.int] = item

proc add*(self: Manifest, cid: Cid) =
  self.rootHash = Cid.none
  trace "Adding cid to manifest", cid
  self.blocks.add(cid)
  self.originalBytes = self.blocks.len * self.blockSize

iterator items*(self: Manifest): Cid =
  for b in self.blocks:
    yield b

iterator pairs*(self: Manifest): tuple[key: int, val: Cid] =
  for pair in self.blocks.pairs():
    yield pair

func contains*(self: Manifest, cid: Cid): bool =
  cid in self.blocks


############################################################
# Various sizes and verification
############################################################

func bytes*(self: Manifest, pad = true): int =
  ## Compute how many bytes corresponding StoreStream(Manifest, pad) will return
  if pad or self.protected:
    self.len * self.blockSize
  else:
    self.originalBytes

func rounded*(self: Manifest): int =
  ## Number of data blocks in *protected* manifest including padding at the end
  roundUp(self.originalLen, self.K)

func steps*(self: Manifest): int =
  ## Number of EC groups in *protected* manifest
  divUp(self.originalLen, self.K)

func verify*(self: Manifest) =
  ## Check manifest correctness
  ##
  let originalLen = (if self.protected: self.originalLen else: self.len)

  if divUp(self.originalBytes, self.blockSize) != originalLen:
    raise newException(Defect, "Broken manifest: wrong originalBytes")

  if self.protected and (self.len != self.steps * (self.K + self.M)):
    raise newException(Defect, "Broken manifest: wrong originalLen")


############################################################
# Cid computation
############################################################

template hashBytes(mh: MultiHash): seq[byte] =
  ## get the hash bytes of a multihash object
  ##

  mh.data.buffer[mh.dpos..(mh.dpos + mh.size - 1)]

proc makeRoot*(self: Manifest): ?!void =
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

  success()

proc cid*(self: Manifest): ?!Cid =
  ## Generate a root hash using the treehash algorithm
  ##

  if self.rootHash.isNone:
    ? self.makeRoot()

  (!self.rootHash).success


############################################################
# Constructors
############################################################

proc new*(
  T: type Manifest,
  blocks: openArray[Cid] = [],
  protected = false,
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
    blockSize: blockSize,
    originalBytes: blocks.len * blockSize,
    protected: protected).success

proc new*(
  T: type Manifest,
  manifest: Manifest,
  K, M: int): ?!Manifest =
  ## Create an erasure protected dataset from an
  ## un-protected one
  ##

  var
    self = Manifest(
      version: manifest.version,
      codec: manifest.codec,
      hcodec: manifest.hcodec,
      originalBytes: manifest.originalBytes,
      blockSize: manifest.blockSize,
      protected: true,
      K: K, M: M,
      originalCid: ? manifest.cid,
      originalLen: manifest.len)

  let
    encodedLen = self.rounded + (self.steps * M)

  self.blocks = newSeq[Cid](encodedLen)

  # copy original manifest blocks
  for i in 0..<self.rounded:
    if i < manifest.len:
      self.blocks[i] = manifest[i]
    else:
      self.blocks[i] = EmptyCid[manifest.version]
      .catch
      .get()[manifest.hcodec]
      .catch
      .get()

  self.verify
  self.success

proc new*(
  T: type Manifest,
  data: openArray[byte],
  decoder = ManifestContainers[$DagPBCodec]): ?!T =
  Manifest.decode(data, decoder)
