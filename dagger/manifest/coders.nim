## Nim-Dagger
## Copyright (c) 2022 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

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

const
  DagPBCodec* = multiCodec("dag-pb")

type
  ManifestCoderType*[codec: static MultiCodec] = object
  DagPBCoder* = ManifestCoderType[multiCodec("dag-pb")]

const
  # TODO: move somewhere better?
  ManifestContainers* = {
    $DagPBCodec: DagPBCoder()
  }.toTable

func encode*(_: DagPBCoder, manifest: Manifest): ?!seq[byte] =
  ## Encode the manifest into a ``ManifestCodec``
  ## multicodec container (Dag-pb) for now
  ##

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
  #   Message Header {
  #     optional bytes rootHash = 1;    # the root (tree) hash
  #     optional uint32 blockSize = 2;  # size of a single block
  #     optional uint32 blocksLen = 3;  # total amount of blocks
  #   }
  # ```
  #

  let cid = !manifest.rootHash
  var header = initProtoBuffer()
  header.write(1, cid.data.buffer)
  header.write(2, manifest.blockSize.uint32)
  header.write(3, manifest.len.uint32)

  pbNode.write(1, header.buffer) # set the rootHash Cid as the data field
  pbNode.finish()

  return pbNode.buffer.success

func decode*(_: DagPBCoder, data: openArray[byte]): ?!Manifest =
  ## Decode a manifest from a data blob
  ##

  var
    pbNode = initProtoBuffer(data)
    pbHeader: ProtoBuffer
    rootHash: seq[byte]
    blockSize: uint32
    blocksLen: uint32
    blocks: seq[Cid]

  # Decode `Header` message
  if pbNode.getField(1, pbHeader).isErr:
    return failure("Unable to decode `Header` from dag-pb manifest!")

  # Decode `Header` contents
  if pbHeader.getField(1, rootHash).isErr:
    return failure("Unable to decode `rootHash` from manifest!")

  if pbHeader.getField(2, blockSize).isErr:
    return failure("Unable to decode `blockSize` from manifest!")

  if pbHeader.getField(3, blocksLen).isErr:
    return failure("Unable to decode `blocksLen` from manifest!")

  let rootHashCid = ? Cid.init(rootHash).mapFailure
  var linksBuf: seq[seq[byte]]
  if pbNode.getRepeatedField(2, linksBuf).isOk:
    for pbLinkBuf in linksBuf:
      var
        blocksBuf: seq[seq[byte]]
        blockBuf: seq[byte]
        pbLink = initProtoBuffer(pbLinkBuf)

      if pbLink.getField(1, blockBuf).isOk:
        blocks.add(? Cid.init(blockBuf).mapFailure)

  if blocksLen.int != blocks.len:
    return failure("Total blocks and length of blocks in header don't match!")

  Manifest(
    rootHash: rootHashCid.some,
    blockSize: blockSize.int,
    blocks: blocks,
    hcodec: (? rootHashCid.mhash.mapFailure).mcodec,
    codec: rootHashCid.mcodec,
    version: rootHashCid.cidver).success

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
