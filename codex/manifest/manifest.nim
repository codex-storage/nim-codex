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
# import pkg/json_serialization

import ../errors
import ../utils
import ../utils/json
import ../units
import ../blocktype
import ./types

export types

type
  Manifest* = ref object of RootObj
    rootHash {.serialize.}: ?Cid          # Root (tree) hash of the contained data set
    originalBytes* {.serialize.}: NBytes  # Exact size of the original (uploaded) file
    blockSize {.serialize.}: NBytes       # Size of each contained block (might not be needed if blocks are len-prefixed)
    blocks: seq[Cid]                      # Block Cid
    version: CidVersion                   # Cid version
    hcodec: MultiCodec                    # Multihash codec
    codec: MultiCodec                     # Data set codec
    case protected {.serialize.}: bool    # Protected datasets have erasure coded info
    of true:
      ecK: int              # Number of blocks to encode
      ecM: int              # Number of resulting parity blocks
      originalCid: Cid      # The original Cid of the dataset being erasure coded
      originalLen: int      # The length of the original manifest
    else:
      discard

############################################################
# Accessors
############################################################

proc blockSize*(self: Manifest): NBytes =
  self.blockSize

proc blocks*(self: Manifest): seq[Cid] =
  self.blocks

proc version*(self: Manifest): CidVersion =
  self.version

proc hcodec*(self: Manifest): MultiCodec =
  self.hcodec

proc codec*(self: Manifest): MultiCodec =
  self.codec

proc protected*(self: Manifest): bool =
  self.protected

proc ecK*(self: Manifest): int =
  self.ecK

proc ecM*(self: Manifest): int =
  self.ecM

proc originalCid*(self: Manifest): Cid =
  self.originalCid

proc originalLen*(self: Manifest): int =
  self.originalLen

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

func isManifest*(cid: Cid): ?!bool =
  let res = ?cid.contentType().mapFailure(CodexError)
  ($(res) in ManifestContainers).success

func isManifest*(mc: MultiCodec): ?!bool =
  ($mc in ManifestContainers).success

proc add*(self: Manifest, cid: Cid) =
  assert not self.protected  # we expect that protected manifests are created with properly-sized self.blocks
  self.rootHash = Cid.none
  trace "Adding cid to manifest", cid
  self.blocks.add(cid)
  self.originalBytes = self.blocks.len.NBytes * self.blockSize

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

func bytes*(self: Manifest, pad = true): NBytes =
  ## Compute how many bytes corresponding StoreStream(Manifest, pad) will return
  if pad or self.protected:
    self.len.NBytes * self.blockSize
  else:
    self.originalBytes

func rounded*(self: Manifest): int =
  ## Number of data blocks in *protected* manifest including padding at the end
  roundUp(self.originalLen, self.ecK)

func steps*(self: Manifest): int =
  ## Number of EC groups in *protected* manifest
  divUp(self.originalLen, self.ecK)

func verify*(self: Manifest): ?!void =
  ## Check manifest correctness
  ##
  let originalLen = (if self.protected: self.originalLen else: self.len)

  if divUp(self.originalBytes, self.blockSize) != originalLen:
    return failure newException(CodexError, "Broken manifest: wrong originalBytes")

  if self.protected and (self.len != self.steps * (self.ecK + self.ecM)):
    return failure newException(CodexError, "Broken manifest: wrong originalLen")

  return success()


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
    let digest = ? EmptyDigests[self.version][self.hcodec].catch
    let cid = ? Cid.init(self.version, self.codec, digest).mapFailure

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
    blockSize = DefaultBlockSize
): ?!Manifest =
  ## Create a manifest using an array of `Cid`s
  ##

  if hcodec notin EmptyDigests[version]:
    return failure("Unsupported manifest hash codec!")

  T(
    blocks: @blocks,
    version: version,
    codec: codec,
    hcodec: hcodec,
    blockSize: blockSize,
    originalBytes: blocks.len.NBytes * blockSize,
    protected: protected).success

proc new*(
    T: type Manifest,
    manifest: Manifest,
    ecK, ecM: int
): ?!Manifest =
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
      ecK: ecK, ecM: ecM,
      originalCid: ? manifest.cid,
      originalLen: manifest.len)

  let
    encodedLen = self.rounded + (self.steps * ecM)

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

  ? self.verify()
  self.success

proc new*(
  T: type Manifest,
  data: openArray[byte],
  decoder = ManifestContainers[$DagPBCodec]
): ?!Manifest =
  ## Create a manifest instance from given data
  ##
  Manifest.decode(data, decoder)

proc new*(
  T: type Manifest,
  rootHash: Cid,
  originalBytes: NBytes,
  blockSize: NBytes,
  blocks: seq[Cid],
  version: CidVersion,
  hcodec: MultiCodec,
  codec: MultiCodec,
  ecK: int,
  ecM: int,
  originalCid: Cid,
  originalLen: int
): Manifest =
  Manifest(
    rootHash: rootHash.some,
    originalBytes: originalBytes,
    blockSize: blockSize,
    blocks: blocks,
    version: version,
    hcodec: hcodec,
    codec: codec,
    protected: true,
    ecK: ecK,
    ecM: ecM,
    originalCid: originalCid,
    originalLen: originalLen
  )

proc new*(
  T: type Manifest,
  rootHash: Cid,
  originalBytes: NBytes,
  blockSize: NBytes,
  blocks: seq[Cid],
  version: CidVersion,
  hcodec: MultiCodec,
  codec: MultiCodec
): Manifest =
  Manifest(
    rootHash: rootHash.some,
    originalBytes: originalBytes,
    blockSize: blockSize,
    blocks: blocks,
    version: version,
    hcodec: hcodec,
    codec: codec,
    protected: false,
  )
