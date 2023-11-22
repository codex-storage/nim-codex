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
import ../utils/json
import ../units
import ../blocktype
import ./types

export types

type
  Encoding = object
      ecK: int                              # Number of blocks to encode
      ecM: int                              # Number of resulting parity blocks
      interleave: int                       # How far apart are blocks of an erasure code according to original index

  Manifest* = ref object of RootObj
    treeCid {.serialize.}: Cid              # Root of the merkle tree
    datasetSize {.serialize.}:  NBytes      # Total size of all blocks
    blockSize {.serialize.}: NBytes         # Size of each contained block (might not be needed if blocks are len-prefixed)
    version: CidVersion                     # Cid version
    hcodec: MultiCodec                      # Multihash codec
    codec: MultiCodec                       # Data set codec
    case protected {.serialize.}: bool      # Protected datasets have erasure coded info
    of true:
      code: Encoding                        # Parameters of the RS code applied
      originalManifest: Manifest            # The original Manifest being erasure coded
    else:
      discard

############################################################
# Accessors
############################################################

proc blockSize*(self: Manifest): NBytes =
  self.blockSize

proc datasetSize*(self: Manifest): NBytes =
  self.datasetSize

proc version*(self: Manifest): CidVersion =
  self.version

proc hcodec*(self: Manifest): MultiCodec =
  self.hcodec

proc codec*(self: Manifest): MultiCodec =
  self.codec

proc protected*(self: Manifest): bool =
  self.protected

proc ecK*(self: Manifest): int =
  self.code.ecK

proc ecM*(self: Manifest): int =
  self.code.ecM

proc interleave*(self: Manifest): int =
  self.code.interleave

proc originalManifest*(self: Manifest): Manifest =
  self.originalManifest

proc originalTreeCid*(self: Manifest): Cid =
  self.originalManifest.treeCid

proc originalBlocksCount*(self: Manifest): int =
  divUp(self.originalManifest.datasetSize.int, self.blockSize.int)

proc unprotectedBlocksCount*(self: Manifest): int =
  var mfest = self
  while mfest.protected:
    mfest = mfest.originalManifest
  divUp(mfest.datasetSize.int, self.blockSize.int)

proc originalDatasetSize*(self: Manifest): NBytes =
  self.originalDatasetSize

proc treeCid*(self: Manifest): Cid =
  self.treeCid

proc blocksCount*(self: Manifest): int =
  divUp(self.datasetSize.int, self.blockSize.int)

proc indexToCoord(encoded: Manifest, idx: int): (int, int, int) {.inline.} =
  let
    column = (idx mod encoded.interleave)
    step = (idx div encoded.interleave) div (encoded.ecK + encoded.ecM)
    pos = (idx div encoded.interleave) mod (encoded.ecK + encoded.ecM)
  (step, column, pos)

func indexToPos(encoded: Manifest, idx: int): int {.inline.} =
  (idx div encoded.interleave) mod (encoded.ecK + encoded.ecM)

func isParity*(self: Manifest, idx: int): bool {.inline.} =
  self.protected and self.indexToPos(idx) >= self.ecK

func oldIndex*(encoded: Manifest, idx: int): int =
  (idx div (encoded.interleave * (encoded.ecK + encoded.ecM))) * (encoded.interleave * encoded.ecK) +
  (idx mod (encoded.interleave * (encoded.ecK + encoded.ecM)))

proc isPadding*(self: Manifest, idx: int): bool =
  var
    mfest = self
    i = idx
  while mfest.protected:
    let coord = mfest.indexToCoord(i)
    if mfest.isParity(i):
      return false
    i = mfest.oldIndex(i)
    mfest = mfest.originalManifest

  result = (i >= mfest.blocksCount)

############################################################
# Operations on block list
############################################################

func isManifest*(cid: Cid): ?!bool =
  let res = ?cid.contentType().mapFailure(CodexError)
  ($(res) in ManifestContainers).success

func isManifest*(mc: MultiCodec): ?!bool =
  ($mc in ManifestContainers).success

############################################################
# Various sizes and verification
############################################################

func bytes*(self: Manifest, pad = true): NBytes =
  ## Compute how many bytes corresponding StoreStream(Manifest, pad) will return
  if pad or self.protected:
    self.blocksCount.NBytes * self.blockSize
  else:
    self.datasetSize

func rounded*(self: Manifest): int =
  ## Number of data blocks in *protected* manifest including padding at the end
  roundUp(self.originalBlocksCount, self.ecK)

func steps*(self: Manifest): int =
  ## Number of EC groups in *protected* manifest
  divUp(self.originalBlocksCount, self.ecK * self.interleave)

func verify*(self: Manifest): ?!void =
  ## Check manifest correctness
  ##

  if self.protected and (self.blocksCount != self.steps * (self.ecK + self.ecM)):
    return failure newException(CodexError, "Broken manifest: wrong originalBlocksCount")

  return success()

proc cid*(self: Manifest): ?!Cid {.deprecated: "use treeCid instead".} =
  self.treeCid.success

proc `==`*(a, b: Manifest): bool =
  (a.treeCid == b.treeCid) and
  (a.datasetSize == b.datasetSize) and
  (a.blockSize == b.blockSize) and
  (a.version == b.version) and
  (a.hcodec == b.hcodec) and
  (a.codec == b.codec) and
  (a.protected == b.protected) and
    (if a.protected:
      (a.ecK == b.ecK) and
      (a.ecM == b.ecM) and
      (a.interleave == b.interleave) and
      (a.originalManifest == b.originalManifest)
    else:
      true)

proc `$`*(self: Manifest): string =
  "treeCid: " & $self.treeCid &
    ", datasetSize: " & $self.datasetSize &
    ", blockSize: " & $self.blockSize &
    ", version: " & $self.version &
    ", hcodec: " & $self.hcodec &
    ", codec: " & $self.codec &
    ", protected: " & $self.protected &
    (if self.protected:
      ", ecK: " & $self.ecK &
      ", ecM: " & $self.ecM &
      ", interleave: " & $self.interleave &
      ", originalManifest: " & $self.originalManifest
    else:
      "")

############################################################
# Constructors
############################################################

proc new*(
    T: type Manifest,
    treeCid: Cid,
    blockSize: NBytes,
    datasetSize: NBytes,
    version: CidVersion = CIDv1,
    hcodec = multiCodec("sha2-256"),
    codec = multiCodec("raw"),
    protected = false,
): Manifest =

  T(
    treeCid: treeCid,
    blockSize: blockSize,
    datasetSize: datasetSize,
    version: version,
    codec: codec,
    hcodec: hcodec,
    protected: protected)

proc new*(
    T: type Manifest,
    manifest: Manifest,
    treeCid: Cid,
    datasetSize: NBytes,
    ecK, ecM: int,
    interleave: int
): Manifest =
  ## Create an erasure protected dataset from an
  ## unprotected one
  ##
  Manifest(
    treeCid: treeCid,
    datasetSize: datasetSize,
    version: manifest.version,
    codec: manifest.codec,
    hcodec: manifest.hcodec,
    blockSize: manifest.blockSize,
    protected: true,
    code: Encoding(
      ecK: ecK,
      ecM: ecM,
      interleave: interleave),
    originalManifest: manifest)

proc new*(
    T: type Manifest,
    manifest: Manifest
): Manifest =
  ## Create an unprotected dataset from an
  ## erasure protected one
  ##
  manifest.originalManifest

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
  treeCid: Cid,
  datasetSize: NBytes,
  blockSize: NBytes,
  version: CidVersion,
  hcodec: MultiCodec,
  codec: MultiCodec,
  ecK: int,
  ecM: int,
  interleave: int,
  originalManifest: Manifest
): Manifest =
  Manifest(
    treeCid: treeCid,
    datasetSize: datasetSize,
    blockSize: blockSize,
    version: version,
    hcodec: hcodec,
    codec: codec,
    protected: true,
    code: Encoding(
      ecK: ecK,
      ecM: ecM,
      interleave: interleave),
    originalManifest: originalManifest
  )
