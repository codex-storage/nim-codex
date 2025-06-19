## Nim-Codex
## Copyright (c) 2021 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

{.push raises: [].}

import pkg/libp2p/cid
import pkg/libp2p/multihash
import pkg/libp2p/protobuf/minprotobuf

import pkg/questionable/results

import ../blocktype
import ./directorymanifest

func decode*(_: type DirectoryManifest, data: openArray[byte]): ?!DirectoryManifest =
  # ```protobuf
  #   Message DirectoryManifest {
  #     Message Cid {
  #       bytes data = 1;
  #     }
  #     string name = 1;
  #     repeated Cid cids = 2;
  # ```

  var
    pbNode = initProtoBuffer(data)
    pbInfo: ProtoBuffer
    name: string
    cids: seq[Cid]
    cidsBytes: seq[seq[byte]]

  if pbNode.getField(1, name).isErr:
    return failure("Unable to decode `name` from DirectoryManifest")

  if ?pbNode.getRepeatedField(2, cidsBytes).mapFailure:
    for cidEntry in cidsBytes:
      var pbCid = initProtoBuffer(cidEntry)
      var dataBuf = newSeq[byte]()
      if pbCid.getField(1, dataBuf).isErr:
        return failure("Unable to decode piece `data` to Cid")
      without cid =? Cid.init(dataBuf).mapFailure, err:
        return failure(err.msg)
      cids.add(cid)

  DirectoryManifest(name: name, cids: cids).success

func decode*(_: type DirectoryManifest, blk: Block): ?!DirectoryManifest =
  ## Decode a directory manifest using `decoder`
  ##

  if not ?blk.cid.isManifest:
    return failure "Cid is not a Directory Manifest Cid"

  DirectoryManifest.decode(blk.data)
