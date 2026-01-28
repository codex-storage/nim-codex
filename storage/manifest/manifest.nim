## Logos Storage
## Copyright (c) 2022 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

# This module defines all operations on Manifest

{.push raises: [], gcsafe.}

import pkg/libp2p/protobuf/minprotobuf
import pkg/libp2p/[cid, multihash, multicodec]
import pkg/questionable/results

import ../errors
import ../utils
import ../utils/json
import ../units
import ../blocktype
import ../logutils

# TODO: Manifest should be reworked to more concrete types,
# perhaps using inheritance
type Manifest* = ref object of RootObj
  treeCid {.serialize.}: Cid # Root of the merkle tree
  datasetSize {.serialize.}: NBytes # Total size of all blocks
  blockSize {.serialize.}: NBytes
    # Size of each contained block (might not be needed if blocks are len-prefixed)
  codec: MultiCodec # Dataset codec
  hcodec: MultiCodec # Multihash codec
  version: CidVersion # Cid version
  filename {.serialize.}: ?string # The filename of the content uploaded (optional)
  mimetype {.serialize.}: ?string # The mimetype of the content uploaded (optional)

############################################################
# Accessors
############################################################

func blockSize*(self: Manifest): NBytes =
  self.blockSize

func datasetSize*(self: Manifest): NBytes =
  self.datasetSize

func version*(self: Manifest): CidVersion =
  self.version

func hcodec*(self: Manifest): MultiCodec =
  self.hcodec

func codec*(self: Manifest): MultiCodec =
  self.codec

func treeCid*(self: Manifest): Cid =
  self.treeCid

func blocksCount*(self: Manifest): int =
  divUp(self.datasetSize.int, self.blockSize.int)

func filename*(self: Manifest): ?string =
  self.filename

func mimetype*(self: Manifest): ?string =
  self.mimetype

############################################################
# Operations on block list
############################################################

func isManifest*(cid: Cid): ?!bool =
  success (ManifestCodec == ?cid.contentType().mapFailure(CodexError))

func isManifest*(mc: MultiCodec): ?!bool =
  success mc == ManifestCodec

############################################################
# Various sizes and verification
############################################################

func `==`*(a, b: Manifest): bool =
  (a.treeCid == b.treeCid) and (a.datasetSize == b.datasetSize) and
    (a.blockSize == b.blockSize) and (a.version == b.version) and (a.hcodec == b.hcodec) and
    (a.codec == b.codec) and (a.filename == b.filename) and (a.mimetype == b.mimetype)

func `$`*(self: Manifest): string =
  result =
    "treeCid: " & $self.treeCid & ", datasetSize: " & $self.datasetSize & ", blockSize: " &
    $self.blockSize & ", version: " & $self.version & ", hcodec: " & $self.hcodec &
    ", codec: " & $self.codec

  if self.filename.isSome:
    result &= ", filename: " & $self.filename

  if self.mimetype.isSome:
    result &= ", mimetype: " & $self.mimetype

  return result

############################################################
# Constructors
############################################################

func new*(
    T: type Manifest,
    treeCid: Cid,
    blockSize: NBytes,
    datasetSize: NBytes,
    version: CidVersion = CIDv1,
    hcodec = Sha256HashCodec,
    codec = BlockCodec,
    filename: ?string = string.none,
    mimetype: ?string = string.none,
): Manifest =
  T(
    treeCid: treeCid,
    blockSize: blockSize,
    datasetSize: datasetSize,
    version: version,
    codec: codec,
    hcodec: hcodec,
    filename: filename,
    mimetype: mimetype,
  )

func new*(T: type Manifest, data: openArray[byte]): ?!Manifest =
  ## Create a manifest instance from given data
  ##

  Manifest.decode(data)
