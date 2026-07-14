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
##     required bytes treeCid = 2;          # cid (root) of the tree
##     required uint32 blockSize = 3;       # size of a single block
##     required uint64 datasetSize = 4;     # size of the dataset
##     required codec: MultiCodec = 5;      # Dataset codec
##     required hcodec: MultiCodec = 6;     # Multihash codec
##     required version: CidVersion = 7;    # Cid version
##     optional filename: string = 8;       # original filename
##     optional mimetype: string = 9;       # original mimetype
##   }
## ```

{.push raises: [].}

import pkg/faststreams
import pkg/libp2p/cid
import pkg/protobuf_serialization
import pkg/protobuf_serialization/codec
import pkg/protobuf_serialization/std/enums
import pkg/questionable
import pkg/questionable/results

import ./manifest
import ../blocktype
import ../utils/protobuf/cid
import ../utils/protobuf/multicodec
import ../utils/protobuf/nbytes
import ../utils/protobuf/option
import ../utils/protobuf/refobject

proc encodeManifestFields(manifest: Manifest): seq[byte] {.raises: [IOError].} =
  encode(Protobuf, manifest)

proc decodeManifestFields(
    fields: seq[byte]
): Manifest {.raises: [SerializationError].} =
  decode(Protobuf, fields, Manifest)

proc encode*(manifest: Manifest): ?!seq[byte] =
  var output = memoryOutput()
  try:
    writeField(output, 1, encodeManifestFields(manifest), pbytes, false)
  except IOError as exc:
    return failure(exc.msg)
  output.getOutput(seq[byte]).success

proc decode*(_: type Manifest, data: openArray[byte]): ?!Manifest =
  try:
    var input = memoryInput(data)
    if not input.readable():
      return failure("Empty manifest input")

    let outer = input.readHeader()
    if outer.number() != 1:
      return failure("Unexpected field number: " & $outer.number())

    var fieldsBytes: seq[byte]
    if not readFieldInto(input, fieldsBytes, outer, pbytes):
      return failure("Unable to decode manifest fields")

    let manifest = decodeManifestFields(fieldsBytes)
    if manifest.manifestVersion != 0:
      return failure("Unsupported manifest version: " & $manifest.manifestVersion)

    manifest.success
  except SerializationError as exc:
    return failure(exc.msg)
  except IOError as exc:
    return failure(exc.msg)

proc decode*(_: type Manifest, blk: Block): ?!Manifest =
  if not ?blk.cid.isManifest:
    return failure "Cid not a manifest codec"

  Manifest.decode(blk.data[])
