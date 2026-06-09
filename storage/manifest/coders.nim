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
import std/options

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
  #     required uint32 manifestVersion = 1; # manifest format version
  #     optional bytes treeCid = 2;          # cid (root) of the tree
  #     optional uint32 blockSize = 3;       # size of a single block
  #     optional uint64 datasetSize = 4;     # size of the dataset
  #     optional codec: MultiCodec = 5;      # Dataset codec
  #     optional hcodec: MultiCodec = 6;     # Multihash codec
  #     optional version: CidVersion = 7;    # Cid version
  #     optional filename: string = 8;       # original filename
  #     optional mimetype: string = 9;       # original mimetype
  #   }
  # ```
  #
  var header = initProtoBuffer()
  header.write(1, manifest.manifestVersion)
  header.write(2, manifest.treeCid.data.buffer)
  header.write(3, manifest.blockSize.uint32)
  header.write(4, manifest.datasetSize.uint64)
  header.write(5, manifest.codec.uint32)
  header.write(6, manifest.hcodec.uint32)
  header.write(7, manifest.version.uint32)

  if manifest.filename.isSome:
    header.write(8, manifest.filename.get())

  if manifest.mimetype.isSome:
    header.write(9, manifest.mimetype.get())

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
    manifestVersion: uint32
    filename: string
    mimetype: string

  # Decode `Header` message
  if pbNode.getField(1, pbHeader).isErr:
    return failure("Unable to decode `Header` from dag-pb manifest!")

  # Decode `Header` contents
  if pbHeader.getField(1, manifestVersion).isErr:
    return failure("Unable to decode `manifestVersion` from manifest!")

  if pbHeader.getField(2, treeCidBuf).isErr:
    return failure("Unable to decode `treeCid` from manifest!")

  if pbHeader.getField(3, blockSize).isErr:
    return failure("Unable to decode `blockSize` from manifest!")

  if pbHeader.getField(4, datasetSize).isErr:
    return failure("Unable to decode `datasetSize` from manifest!")

  if pbHeader.getField(5, codec).isErr:
    return failure("Unable to decode `codec` from manifest!")

  if pbHeader.getField(6, hcodec).isErr:
    return failure("Unable to decode `hcodec` from manifest!")

  if pbHeader.getField(7, version).isErr:
    return failure("Unable to decode `version` from manifest!")

  if pbHeader.getField(8, filename).isErr:
    return failure("Unable to decode `filename` from manifest!")

  if pbHeader.getField(9, mimetype).isErr:
    return failure("Unable to decode `mimetype` from manifest!")

  if manifestVersion != 0:
    return failure("Unsupported manifest version: " & $manifestVersion)

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
    manifestVersion = manifestVersion,
  )

  self.success

func decode*(_: type Manifest, blk: Block): ?!Manifest =
  ## Decode a manifest using `decoder`
  ##

  if not ?blk.cid.isManifest:
    return failure "Cid not a manifest codec"

  Manifest.decode(blk.data[])
