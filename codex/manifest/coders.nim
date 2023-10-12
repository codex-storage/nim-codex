## Nim-Codex
## Copyright (c) 2022 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

# This module implements serialization and deserialization of Manifest

import pkg/upraises

push: {.upraises: [].}

import std/tables

import pkg/libp2p
import pkg/questionable
import pkg/questionable/results
import pkg/chronicles
import pkg/chronos

import ./manifest
import ../errors
import ../blocktype
import ./types

proc encode*(_: DagPBCoder, manifest: Manifest): ?!seq[byte] =
  ## Encode the manifest into a ``ManifestCodec``
  ## multicodec container (Dag-pb) for now
  ##

  ? manifest.verify()
  var pbNode = initProtoBuffer()

  # NOTE: The `Data` field in the the `dag-pb`
  # contains the following protobuf `Message`
  #
  # ```protobuf
  #   Message ErasureInfo {
  #     optional uint32 K = 1;          # number of encoded blocks
  #     optional uint32 M = 2;          # number of parity blocks
  #     optional bytes cid = 3;         # cid of the original dataset
  #     optional uint32 original = 4;   # number of original blocks
  #   }
  #   Message Header {
  #     optional bytes treeCid = 1;       # the cid of the tree
  #     optional bytes treeRoot = 2;      # the root hash of the tree
  #     optional uint32 blockSize = 3;    # size of a single block
  #     optional uint64 originalBytes = 4;# exact file size
  #     optional ErasureInfo erasure = 5; # erasure coding info
  #   }
  # ```
  #
  # var treeRootVBuf = initVBuffer()
  var header = initProtoBuffer()
  header.write(1, manifest.treeCid.data.buffer)
  # treeRootVBuf.write(manifest.treeRoot)
  header.write(2, manifest.treeRoot.data.buffer)
  header.write(3, manifest.blockSize.uint32)
  header.write(4, manifest.datasetSize.uint32)
  if manifest.protected:
    var erasureInfo = initProtoBuffer()
    erasureInfo.write(1, manifest.ecK.uint32)
    erasureInfo.write(2, manifest.ecM.uint32)
    erasureInfo.write(3, manifest.originalCid.data.buffer)
    erasureInfo.write(4, manifest.originalTreeRoot.data.buffer)
    erasureInfo.write(5, manifest.originalDatasetSize.uint32)
    erasureInfo.finish()

    header.write(5, erasureInfo)

  pbNode.write(1, header) # set the treeCid as the data field
  pbNode.finish()

  return pbNode.buffer.success

proc decode*(_: DagPBCoder, data: openArray[byte]): ?!Manifest =
  ## Decode a manifest from a data blob
  ##

  var
    pbNode = initProtoBuffer(data)
    pbHeader: ProtoBuffer
    pbErasureInfo: ProtoBuffer
    treeCidBuf: seq[byte]
    treeRootBuf: seq[byte]
    originalTreeCid: seq[byte]
    originalTreeRootBuf: seq[byte]
    datasetSize: uint32
    blockSize: uint32
    originalDatasetSize: uint32
    ecK, ecM: uint32

  # Decode `Header` message
  if pbNode.getField(1, pbHeader).isErr:
    return failure("Unable to decode `Header` from dag-pb manifest!")

  # Decode `Header` contents
  if pbHeader.getField(1, treeCidBuf).isErr:
    return failure("Unable to decode `treeCid` from manifest!")

  if pbHeader.getField(2, treeRootBuf).isErr:
    return failure("Unable to decode `treeRoot` from manifest!")

  if pbHeader.getField(3, blockSize).isErr:
    return failure("Unable to decode `blockSize` from manifest!")

  if pbHeader.getField(4, datasetSize).isErr:
    return failure("Unable to decode `datasetSize` from manifest!")

  if pbHeader.getField(5, pbErasureInfo).isErr:
    return failure("Unable to decode `erasureInfo` from manifest!")

  let protected = pbErasureInfo.buffer.len > 0
  if protected:
    if pbErasureInfo.getField(1, ecK).isErr:
      return failure("Unable to decode `K` from manifest!")

    if pbErasureInfo.getField(2, ecM).isErr:
      return failure("Unable to decode `M` from manifest!")

    if pbErasureInfo.getField(3, originalTreeCid).isErr:
      return failure("Unable to decode `originalTreeCid` from manifest!")
    
    if pbErasureInfo.getField(4, originalTreeRootBuf).isErr:
      return failure("Unable to decode `originalTreeRoot` from manifest!")

    if pbErasureInfo.getField(5, originalDatasetSize).isErr:
      return failure("Unable to decode `originalDatasetSize` from manifest!")

  var 
    treeRoot: MultiHash
    originalTreeRoot: MultiHash

  let 
    treeCid = ? Cid.init(treeCidBuf).mapFailure
    treeRootRes = ? MultiHash.decode(treeRootBuf, treeRoot).mapFailure

  if treeRootRes != treeRootBuf.len:
    return failure("Error decoding `treeRoot` as MultiHash")
  
  if protected:
    let originalTreeRootRes = ? MultiHash.decode(originalTreeRootBuf, originalTreeRoot).mapFailure
    if originalTreeRootRes != originalTreeRootBuf.len:
      return failure("Error decoding `originalTreeRoot` as MultiHash")

  let
    self = if protected:
      Manifest.new(
        treeCid = treeCid,
        treeRoot = treeRoot,
        datasetSize = datasetSize.NBytes,
        blockSize = blockSize.NBytes,
        version = treeCid.cidver,
        hcodec = (? treeCid.mhash.mapFailure).mcodec,
        codec = treeCid.mcodec,
        ecK = ecK.int,
        ecM = ecM.int,
        originalTreeCid = ? Cid.init(originalTreeCid).mapFailure,
        originalTreeRoot = originalTreeRoot,
        originalDatasetSize = originalDatasetSize.NBytes
      )
      else:
        Manifest.new(
          treeCid = treeCid,
          treeRoot = treeRoot,
          datasetSize = datasetSize.NBytes,
          blockSize = blockSize.NBytes,
          version = treeCid.cidver,
          hcodec = (? treeCid.mhash.mapFailure).mcodec,
          codec = treeCid.mcodec
        )

  ? self.verify()
  self.success

proc encode*(
    self: Manifest,
    encoder = ManifestContainers[$DagPBCodec]
): ?!seq[byte] =
  ## Encode a manifest using `encoder`
  ##

  encoder.encode(self)

func decode*(
    _: type Manifest,
    data: openArray[byte],
    decoder = ManifestContainers[$DagPBCodec]
): ?!Manifest =
  ## Decode a manifest using `decoder`
  ##

  decoder.decode(data)

func decode*(_: type Manifest, blk: Block): ?!Manifest =
  ## Decode a manifest using `decoder`
  ##

  if not ? blk.cid.isManifest:
    return failure "Cid not a manifest codec"

  Manifest.decode(
    blk.data,
    ? ManifestContainers[$(?blk.cid.contentType().mapFailure)].catch)
