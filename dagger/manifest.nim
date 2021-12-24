## Nim-Dagger
## Copyright (c) 2021 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

{.push raises: [Defect].}

import pkg/libp2p
import pkg/libp2p/protobuf/minprotobuf
import pkg/questionable
import pkg/questionable/results
import pkg/chronicles
import pkg/chronos

import ./blocktype
import ./errors

const
  ManifestCodec* = multiCodec("dag-pb")

var
  emptyDigest {.threadvar.}: array[CidVersion, MultiHash]

type
  BlocksManifest* = object
    blocks: seq[Cid]
    htree: ?Cid
    version*: CidVersion
    hcodec*: MultiCodec
    codec*: MultiCodec

proc len*(b: BlocksManifest): int = b.blocks.len

iterator items*(b: BlocksManifest): Cid =
  for b in b.blocks:
    yield b

proc hashBytes(mh: MultiHash): seq[byte] =
  mh.data.buffer[mh.dpos..(mh.dpos + mh.size - 1)]

proc cid*(b: var BlocksManifest): ?!Cid =
  if htree =? b.htree:
    return htree.success

  var
    stack: seq[MultiHash]

  if stack.len == 1:
    stack.add(emptyDigest[b.version])

  for cid in b.blocks:
    stack.add(? cid.mhash.mapFailure)

    while stack.len > 1:
      let
        (b1, b2) = (stack.pop(), stack.pop())
        mh = ? MultiHash.digest(
          $b.hcodec,
          (b1.hashBytes() & b2.hashBytes()))
          .mapFailure
      stack.add(mh)

  if stack.len == 1:
    let cid = ? Cid.init(b.version, b.codec, stack[0]).mapFailure
    b.htree = cid.some
    return cid.success

proc put*(b: var BlocksManifest, cid: Cid) =
  b.htree = Cid.none
  trace "Adding cid to manifest", cid
  b.blocks.add(cid)

proc contains*(b: BlocksManifest, cid: Cid): bool =
  cid in b.blocks

proc encode*(b: var BlocksManifest): ?!seq[byte] =
  ## Encode the manifest into a ``ManifestCodec``
  ## multicodec container (Dag-pb) for now
  var pbNode = initProtoBuffer()

  for c in b.blocks:
    var pbLink = initProtoBuffer()
    pbLink.write(1, c.data.buffer) # write Cid links
    pbLink.finish()
    pbNode.write(2, pbLink)

  let cid = ? b.cid
  pbNode.write(1, cid.data.buffer) # set the treeHash Cid as the data field
  pbNode.finish()

  return pbNode.buffer.success

proc decode*(_: type BlocksManifest, data: seq[byte]): ?!(Cid, seq[Cid]) =
  ## Decode a manifest from a byte seq
  ##
  var
    pbNode = initProtoBuffer(data)
    cidBuf: seq[byte]
    blocks: seq[Cid]

  if pbNode.getField(1, cidBuf).isOk:
    let cid = ? Cid.init(cidBuf).mapFailure
    var linksBuf: seq[seq[byte]]
    if pbNode.getRepeatedField(2, linksBuf).isOk:
      for pbLinkBuf in linksBuf:
        var
          blocksBuf: seq[seq[byte]]
          blockBuf: seq[byte]
          pbLink = initProtoBuffer(pbLinkBuf)

        if pbLink.getField(1, blockBuf).isOk:
          let cidRes = Cid.init(blockBuf)
          if cidRes.isOk:
            blocks.add(cidRes.get())

      return (cid, blocks).success

proc init*(
  T: type BlocksManifest,
  blocks: openArray[Cid] = [],
  version = CIDv1,
  hcodec = multiCodec("sha2-256"),
  codec = multiCodec("raw")): ?!T =
  ## Create a manifest using array of `Cid`s
  ##

  # Only gets initialized once
  once:
    # TODO: The CIDs should be initialized at compile time,
    # but the VM fails due to a `memmove` being invoked somewhere

    for v in [CIDv0, CIDv1]:
      let
        cid = if v == CIDv1:
          ? Cid.init("bafybeihdwdcefgh4dqkjv67uzcmw7ojee6xedzdetojuzjevtenxquvyku").mapFailure
        else:
          ? Cid.init("QmdfTbBqBPQ7VNxZEYEj14VmRuZBkqFbiwReogJgS1zR1n").mapFailure

        mhash = ? cid.mhash.mapFailure
        digest = ? MultiHash.digest(
          $hcodec,
          mhash.hashBytes()).mapFailure

      emptyDigest[v] = digest

  T(
    blocks: @blocks,
    version: version,
    codec: codec,
    hcodec: hcodec,
    ).success

proc init*(
  T: type BlocksManifest,
  blk: Block): ?!T =
  ## Create manifest from a raw manifest block
  ## (in dag-pb for for now)
  ##

  let
    (cid, blocks) = ? BlocksManifest.decode(blk.data)
    mhash = ? cid.mhash.mapFailure

  var
    manifest = ? BlocksManifest.init(
      blocks,
      cid.version,
      mhash.mcodec,
      cid.mcodec)

  if cid != (? manifest.cid):
    return failure("Content hashes don't match!")

  return manifest.success
