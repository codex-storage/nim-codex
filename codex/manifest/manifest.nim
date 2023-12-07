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
  Manifest* = ref object of RootObj
    treeCid {.serialize.}: Cid              # Root of the merkle tree
    datasetSize {.serialize.}:  NBytes      # Total size of all blocks
    blockSize {.serialize.}: NBytes         # Size of each contained block (might not be needed if blocks are len-prefixed)
    version: CidVersion                     # Cid version
    hcodec: MultiCodec                      # Multihash codec
    codec: MultiCodec                       # Data set codec
    case protected {.serialize.}: bool      # Protected datasets have erasure coded info
    of true:
      ecK: int                              # Number of blocks to encode
      ecM: int                              # Number of resulting parity blocks
      originalTreeCid: Cid                  # The original root of the dataset being erasure coded
      originalDatasetSize: NBytes
      case verifiable {.serialize.}: bool   # Verifiable datasets can be used to generate storage proofs
      of true:
        verificationRoot: Cid
        slotRoots: seq[Cid]
      else:
        discard
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
  self.ecK

proc ecM*(self: Manifest): int =
  self.ecM

proc originalTreeCid*(self: Manifest): Cid =
  self.originalTreeCid

proc originalBlocksCount*(self: Manifest): int =
  divUp(self.originalDatasetSize.int, self.blockSize.int)

proc originalDatasetSize*(self: Manifest): NBytes =
  self.originalDatasetSize

proc treeCid*(self: Manifest): Cid =
  self.treeCid

proc blocksCount*(self: Manifest): int =
  divUp(self.datasetSize.int, self.blockSize.int)

proc verifiable*(self: Manifest): bool =
  self.verifiable

proc verificationRoot*(self: Manifest): Cid =
  self.verificationRoot

proc slotRoots*(self: Manifest): seq[Cid] =
  self.slotRoots

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
  divUp(self.originalBlocksCount, self.ecK)

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
      (a.originalTreeCid == b.originalTreeCid) and
      (a.originalDatasetSize == b.originalDatasetSize) and
      (a.verifiable == b.verifiable) and
        (if a.verifiable:
          (a.verificationRoot == b.verificationRoot) and
          (a.slotRoots == b.slotRoots)
        else:
          true)
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
      ", originalTreeCid: " & $self.originalTreeCid &
      ", originalDatasetSize: " & $self.originalDatasetSize &
      ", verifiable: " & $self.verifiable &
      (if self.verifiable:
        ", verificationRoot: " & $self.verificationRoot &
        ", slotRoots: " & $self.slotRoots
      else:
        "")
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
    ecK, ecM: int
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
    ecK: ecK, ecM: ecM,
    originalTreeCid: manifest.treeCid,
    originalDatasetSize: manifest.datasetSize)

proc new*(
    T: type Manifest,
    manifest: Manifest
): Manifest =
  ## Create an unprotected dataset from an
  ## erasure protected one
  ##
  Manifest(
    treeCid: manifest.originalTreeCid,
    datasetSize: manifest.originalDatasetSize,
    version: manifest.version,
    codec: manifest.codec,
    hcodec: manifest.hcodec,
    blockSize: manifest.blockSize,
    protected: false)

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
  originalTreeCid: Cid,
  originalDatasetSize: NBytes
): Manifest =
  Manifest(
    treeCid: treeCid,
    datasetSize: datasetSize,
    blockSize: blockSize,
    version: version,
    hcodec: hcodec,
    codec: codec,
    protected: true,
    ecK: ecK,
    ecM: ecM,
    originalTreeCid: originalTreeCid,
    originalDatasetSize: originalDatasetSize
  )

proc new*(
    T: type Manifest,
    manifest: Manifest,
    verificationRoot: Cid,
    slotRoots: seq[Cid]
): ?!Manifest =
  ## Create a verifiable dataset from an
  ## protected one
  ##
  if not manifest.protected:
    return failure newException(CodexError, "Can create verifiable manifest only from protected manifest.")

  success(Manifest(
    treeCid: manifest.treeCid,
    datasetSize: manifest.datasetSize,
    version: manifest.version,
    codec: manifest.codec,
    hcodec: manifest.hcodec,
    blockSize: manifest.blockSize,
    protected: true,
    ecK: manifest.ecK,
    ecM: manifest.ecM,
    originalTreeCid: manifest.treeCid,
    originalDatasetSize: manifest.originalDatasetSize,
    verifiable: true,
    verificationRoot: verificationRoot,
    slotRoots: slotRoots
  ))
