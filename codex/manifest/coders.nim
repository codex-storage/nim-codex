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

  for c in manifest.blocks:
    var pbLink = initProtoBuffer()
    pbLink.write(1, c.data.buffer) # write Cid links
    pbLink.finish()
    pbNode.write(2, pbLink)

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
  #     optional bytes treeCid = 1;      # the root (tree) hash
  #     optional bytes treeRoot = 2;      # the root (tree) hash
  #     optional uint32 blockSize = 3;    # size of a single block
  #     optional uint32 blocksLen = 4;    # total amount of blocks
  #     optional ErasureInfo erasure = 5; # erasure coding info
  #     optional uint64 originalBytes = 6;# exact file size
  #   }
  # ```
  #
  var treeRootVBuf = initVBuffer()
  var header = initProtoBuffer()
  header.write(1, manifest.treeCid.data.buffer)
  treeRootVBuf.write(manifest.treeRoot)
  header.write(2, treeRootVBuf.buffer)
  header.write(3, manifest.blockSize.uint32)
  header.write(4, manifest.len.uint32)
  header.write(6, manifest.originalBytes.uint64)
  if manifest.protected:
    var erasureInfo = initProtoBuffer()
    erasureInfo.write(1, manifest.ecK.uint32)
    erasureInfo.write(2, manifest.ecM.uint32)
    erasureInfo.write(3, manifest.originalCid.data.buffer)
    erasureInfo.write(4, manifest.originalLen.uint32)
    erasureInfo.finish()

    header.write(5, erasureInfo)

  pbNode.write(1, header) # set the treeCid as the data field
  pbNode.finish()

  return pbNode.buffer.success

func decode*(_: DagPBCoder, data: openArray[byte]): ?!Manifest =
  ## Decode a manifest from a data blob
  ##

  var
    pbNode = initProtoBuffer(data)
    pbHeader: ProtoBuffer
    pbErasureInfo: ProtoBuffer
    treeCidBuf: seq[byte]
    treeRootBuf: seq[byte]
    originalCid: seq[byte]
    originalBytes: uint64
    blockSize: uint32
    blocksLen: uint32
    originalLen: uint32
    ecK, ecM: uint32
    blocks: seq[Cid]

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

  if pbHeader.getField(4, blocksLen).isErr:
    return failure("Unable to decode `blocksLen` from manifest!")

  if pbHeader.getField(6, originalBytes).isErr:
    return failure("Unable to decode `originalBytes` from manifest!")

  if pbHeader.getField(5, pbErasureInfo).isErr:
    return failure("Unable to decode `erasureInfo` from manifest!")

  if pbErasureInfo.buffer.len > 0:
    if pbErasureInfo.getField(1, ecK).isErr:
      return failure("Unable to decode `K` from manifest!")

    if pbErasureInfo.getField(2, ecM).isErr:
      return failure("Unable to decode `M` from manifest!")

    if pbErasureInfo.getField(3, originalCid).isErr:
      return failure("Unable to decode `originalCid` from manifest!")

    if pbErasureInfo.getField(4, originalLen).isErr:
      return failure("Unable to decode `originalLen` from manifest!")

  var 
    linksBuf: seq[seq[byte]]
    treeRoot: MultiHash
  let 
    treeCid = ? Cid.init(treeCidBuf).mapFailure
    res = ? MultiHash.decode(treeRootBuf, treeRoot).mapFailure

  if res != treeRootBuf.len:
    return failure("Error decoding `treeRoot` as MultiHash")

  if pbNode.getRepeatedField(2, linksBuf).isOk:
    for pbLinkBuf in linksBuf:
      var
        blockBuf: seq[byte]
        pbLink = initProtoBuffer(pbLinkBuf)

      if pbLink.getField(1, blockBuf).isOk:
        blocks.add(? Cid.init(blockBuf).mapFailure)

  if blocksLen.int != blocks.len:
    return failure("Total blocks and length of blocks in header don't match!")

  let
    self = if pbErasureInfo.buffer.len > 0:
      Manifest.new(
        treeCid = treeCid,
        treeRoot = treeRoot,
        originalBytes = originalBytes.NBytes,
        blockSize = blockSize.NBytes,
        blocks = blocks,
        version = treeCid.cidver,
        hcodec = (? treeCid.mhash.mapFailure).mcodec,
        codec = treeCid.mcodec,
        ecK = ecK.int,
        ecM = ecM.int,
        originalCid = ? Cid.init(originalCid).mapFailure,
        originalLen = originalLen.int
      )
      else:
        Manifest.new(
          treeCid = treeCid,
          treeRoot = treeRoot,
          originalBytes = originalBytes.NBytes,
          blockSize = blockSize.NBytes,
          blocks = blocks,
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
