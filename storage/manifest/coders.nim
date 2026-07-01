## Logos Storage
## Copyright (c) 2022 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

## This module implements serialization and deserialization of Manifest.
##
## ```protobuf
##   Message Manifest {
##     required uint32 manifestVersion = 1; # manifest format version
##     optional bytes treeCid = 2;          # cid (root) of the tree
##     optional uint32 blockSize = 3;       # size of a single block
##     optional uint64 datasetSize = 4;     # size of the dataset
##     optional codec: MultiCodec = 5;      # Dataset codec
##     optional hcodec: MultiCodec = 6;     # Multihash codec
##     optional version: CidVersion = 7;    # Cid version
##     optional filename: string = 8;       # original filename
##     optional mimetype: string = 9;       # original mimetype
##   }
## ```

{.push raises: [].}

import std/options

import pkg/faststreams
import pkg/libp2p/cid
import pkg/libp2p/multicodec
import pkg/protobuf_serialization
import pkg/protobuf_serialization/codec
import pkg/questionable
import pkg/questionable/results

import ./manifest
import ../blocktype
import ../errors

proc writeManifestFields(
    stream: OutputStream, manifest: Manifest
) {.raises: [IOError].} =
  writeField(stream, 1, manifest.manifestVersion, puint32, false)
  writeField(stream, 2, manifest.treeCid.data.buffer, pbytes, false)
  writeField(stream, 3, manifest.blockSize.uint64, puint64, false)
  writeField(stream, 4, manifest.datasetSize.uint64, puint64, false)
  writeField(stream, 5, manifest.codec.uint32, puint32, false)
  writeField(stream, 6, manifest.hcodec.uint32, puint32, false)
  writeField(stream, 7, manifest.version.uint32, puint32, false)
  if manifest.filename.isSome:
    writeField(stream, 8, manifest.filename.get(), pstring, false)
  if manifest.mimetype.isSome:
    writeField(stream, 9, manifest.mimetype.get(), pstring, false)

proc encode*(manifest: Manifest): ?!seq[byte] =
  var
    output = memoryOutput()
    fields = memoryOutput()
  try:
    writeManifestFields(fields, manifest)
    writeField(output, 1, fields.getOutput(seq[byte]), pbytes, false)
  except IOError as exc:
    return failure(exc.msg)
  output.getOutput(seq[byte]).success

proc decode*(_: type Manifest, data: openArray[byte]): ?!Manifest =
  var
    manifestVersion: uint32
    treeCidBuf: seq[byte]
    blockSize: uint64
    datasetSize: uint64
    codec: uint32
    hcodec: uint32
    versionRaw: uint32
    filename = string.none
    mimetype = string.none

  try:
    var input = memoryInput(data)
    if not input.readable():
      return failure("Empty manifest input")

    let outer = input.readHeader()
    if outer.number() != 1:
      return failure("Unexpected top-level field number: " & $outer.number())

    var fieldsBytes: seq[byte]
    if not readFieldInto(input, fieldsBytes, outer, pbytes):
      return failure("Unable to decode manifest fields")

    var fields = memoryInput(fieldsBytes)
    while fields.readable():
      let h = fields.readHeader()
      case h.number()
      of 1:
        discard readFieldInto(fields, manifestVersion, h, puint32)
      of 2:
        discard readFieldInto(fields, treeCidBuf, h, pbytes)
      of 3:
        discard readFieldInto(fields, blockSize, h, puint64)
      of 4:
        discard readFieldInto(fields, datasetSize, h, puint64)
      of 5:
        discard readFieldInto(fields, codec, h, puint32)
      of 6:
        discard readFieldInto(fields, hcodec, h, puint32)
      of 7:
        discard readFieldInto(fields, versionRaw, h, puint32)
      of 8:
        var s: string
        discard readFieldInto(fields, s, h, pstring)
        if s.len > 0:
          filename = s.some
      of 9:
        var s: string
        discard readFieldInto(fields, s, h, pstring)
        if s.len > 0:
          mimetype = s.some
      else:
        case h.kind()
        of WireKind.Varint:
          fields.skipValue(puint64)
        of WireKind.Fixed64:
          fields.skipValue(fixed64)
        of WireKind.LengthDelim:
          fields.skipValue(pbytes)
        of WireKind.Fixed32:
          fields.skipValue(fixed32)
  except SerializationError as exc:
    return failure(exc.msg)
  except IOError as exc:
    return failure(exc.msg)

  if manifestVersion != 0:
    return failure("Unsupported manifest version: " & $manifestVersion)

  let treeCid = ?Cid.init(treeCidBuf).mapFailure

  Manifest.new(
    manifestVersion = manifestVersion,
    treeCid = treeCid,
    datasetSize = datasetSize.NBytes,
    blockSize = blockSize.NBytes,
    codec = codec.MultiCodec,
    hcodec = hcodec.MultiCodec,
    version = CidVersion(versionRaw),
    filename = filename,
    mimetype = mimetype,
  ).success

proc decode*(_: type Manifest, blk: Block): ?!Manifest =
  if not ?blk.cid.isManifest:
    return failure "Cid not a manifest codec"

  Manifest.decode(blk.data[])
