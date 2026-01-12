## Logos Storage
## Copyright (c) 2022 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

# This module implements serialization and deserialization of Manifest

import times

{.push raises: [].}

import std/tables
import std/sequtils

import pkg/libp2p
import pkg/questionable
import pkg/questionable/results
import pkg/chronos

import ./manifest
import ../errors
import ../blocktype
import ../logutils

proc encode*(manifest: Manifest): ?!seq[byte] =
  ## Encode the manifest into a ``ManifestCodec``
  ## multicodec container (Dag-pb) for now
  ##

  var pbNode = initProtoBuffer()

  # NOTE: The `Data` field in the the `dag-pb`
  # contains the following protobuf `Message`
  #
  # ```protobuf
  #   Message Header {
  #     optional bytes treeCid = 1;       # cid (root) of the tree
  #     optional uint32 blockSize = 2;    # size of a single block
  #     optional uint64 datasetSize = 3;  # size of the dataset
  #     optional codec: MultiCodec = 4;   # Dataset codec
  #     optional hcodec: MultiCodec = 5   # Multihash codec
  #     optional version: CidVersion = 6; # Cid version
  #     optional filename: ?string = 7;    # original filename
  #     optional mimetype: ?string = 8;    # original mimetype
  #   }
  # ```
  #
  # var treeRootVBuf = initVBuffer()
  var header = initProtoBuffer()
  header.write(1, manifest.treeCid.data.buffer)
  header.write(2, manifest.blockSize.uint32)
  header.write(3, manifest.datasetSize.uint64)
  header.write(4, manifest.codec.uint32)
  header.write(5, manifest.hcodec.uint32)
  header.write(6, manifest.version.uint32)

  if manifest.filename.isSome:
    header.write(7, manifest.filename.get())

  if manifest.mimetype.isSome:
    header.write(8, manifest.mimetype.get())

  pbNode.write(1, header) # set the treeCid as the data field
  pbNode.finish()

  return pbNode.buffer.success

proc decode*(_: type Manifest, data: openArray[byte]): ?!Manifest =
  ## Decode a manifest from a data blob
  ##

  var
    pbNode = initProtoBuffer(data)
    pbHeader: ProtoBuffer
    treeCidBuf: seq[byte]
    datasetSize: uint64
    codec: uint32
    hcodec: uint32
    version: uint32
    blockSize: uint32
    filename: string
    mimetype: string

  # Decode `Header` message
  if pbNode.getField(1, pbHeader).isErr:
    return failure("Unable to decode `Header` from dag-pb manifest!")

  # Decode `Header` contents
  if pbHeader.getField(1, treeCidBuf).isErr:
    return failure("Unable to decode `treeCid` from manifest!")

  if pbHeader.getField(2, blockSize).isErr:
    return failure("Unable to decode `blockSize` from manifest!")

  if pbHeader.getField(3, datasetSize).isErr:
    return failure("Unable to decode `datasetSize` from manifest!")

  if pbHeader.getField(4, codec).isErr:
    return failure("Unable to decode `codec` from manifest!")

  if pbHeader.getField(5, hcodec).isErr:
    return failure("Unable to decode `hcodec` from manifest!")

  if pbHeader.getField(6, version).isErr:
    return failure("Unable to decode `version` from manifest!")

  if pbHeader.getField(7, filename).isErr:
    return failure("Unable to decode `filename` from manifest!")

  if pbHeader.getField(8, mimetype).isErr:
    return failure("Unable to decode `mimetype` from manifest!")

  let treeCid = ?Cid.init(treeCidBuf).mapFailure

  var filenameOption = if filename.len == 0: string.none else: filename.some
  var mimetypeOption = if mimetype.len == 0: string.none else: mimetype.some

  let self = Manifest.new(
    treeCid = treeCid,
    datasetSize = datasetSize.NBytes,
    blockSize = blockSize.NBytes,
    version = CidVersion(version),
    hcodec = hcodec.MultiCodec,
    codec = codec.MultiCodec,
    filename = filenameOption,
    mimetype = mimetypeOption,
  )

  self.success

func decode*(_: type Manifest, blk: Block): ?!Manifest =
  ## Decode a manifest using `decoder`
  ##

  if not ?blk.cid.isManifest:
    return failure "Cid not a manifest codec"

  Manifest.decode(blk.data)
