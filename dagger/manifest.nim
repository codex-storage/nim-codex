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

const
  ManifestCodec* = multiCodec("dag-pb")

type
  BlocksManifest* = object
    blocks: seq[Cid]
    htree: ?Cid
    version*: CidVersion
    hcodec*: MultiCodec
    codec*: MultiCodec
    cidEmptyDigest: MultiHash

proc len*(b: BlocksManifest): int = b.blocks.len

iterator items*(b: BlocksManifest): Cid =
  for b in b.blocks:
    yield b

proc hashBytes(mh: MultiHash): seq[byte] =
  mh.data.buffer[mh.dpos..(mh.dpos + mh.size - 1)]

proc cid*(b: var BlocksManifest): ?Cid =
  if b.htree.isSome:
    return b.htree

  var
    stack: seq[MultiHash]

  if stack.len == 1:
    stack.add(b.cidEmptyDigest)

  for cid in b.blocks:
    if mhash =? cid.mhash:
      stack.add(mhash)

    while stack.len > 1:
      var
        (b1, b2) = (stack.pop(), stack.pop())

      var
        digest = MultiHash.digest(
          $b.hcodec,
          (b1.hashBytes() & b2.hashBytes()))

      without mh =? digest:
        return Cid.none

      stack.add(mh)

  if stack.len == 1:
    let
      cid = Cid.init(b.version, b.codec, stack[0])

    if cid.isOk:
      b.htree = cid.get().some
      return cid.get().some

proc put*(b: var BlocksManifest, cid: Cid) =
  if b.htree.isSome:
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

  without cid =? b.cid:
    return failure("Unable to generate tree hash")

  pbNode.write(1, cid.data.buffer) # set the treeHash Cid as the data field
  pbNode.finish()

  return pbNode.buffer.success

proc decode*(_: type BlocksManifest, data: seq[byte]): ?!(Cid, seq[Cid]) =
  ## Decode a manifest from a byte seq
  ##
  var pbNode = initProtoBuffer(data)
  var
    cidBuf: seq[byte]
    blocks: seq[Cid]

  if pbNode.getField(1, cidBuf).isOk:
    if cid =? Cid.init(cidBuf):
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

func init*(
  T: type BlocksManifest,
  blocks: openArray[Cid] = [],
  version = CIDv1,
  hcodec = multiCodec("sha2-256"),
  codec = multiCodec("raw")): ?!T =
  ## Create a manifest using array of `Cid`s
  ##

  # TODO: The CIDs should be initialized at compile time,
  # but the VM fails due to a `memmove` being invoked somewhere
  let cidEmptyRes = if version == CIDv1:
      Cid.init("bafybeihdwdcefgh4dqkjv67uzcmw7ojee6xedzdetojuzjevtenxquvyku")
    else:
      Cid.init("QmdfTbBqBPQ7VNxZEYEj14VmRuZBkqFbiwReogJgS1zR1n")

  without cidEmpty =? cidEmptyRes:
    return failure("Unable to create empty Cid")

  without cidEmptyMHash =? cidEmpty.mhash:
    return failure("Unable to get multihash from empty Cid")

  without cidEmptyDigest =? MultiHash.digest(
      $hcodec,
      cidEmptyMHash.hashBytes()):
    return failure("Unable to generate digest for empty Cid")

  T(
    blocks: @blocks,
    version: version,
    codec: codec,
    hcodec: hcodec,
    cidEmptyDigest: cidEmptyDigest
    ).success

func init*(
  T: type BlocksManifest,
  blk: Block): ?!T =
  ## Create manifest from a raw manifest block
  ## (in dag-pb for for now)
  ##

  let res = BlocksManifest.decode(blk.data)
  if res.isErr:
    return failure("Unable to decode Block to a Block Set!")

  let
    (cid, blocks) = res.get()

  without mhash =? cid.mhash:
    return failure("Unable to get contents mhash!")

  without var manifest =? BlocksManifest.init(
      blocks,
      cid.version,
      mhash.mcodec,
      cid.mcodec):
    return failure("Unable to get construct block manifest")

  without manifestCid =? manifest.cid:
    return failure("Couldn't get manifest tree hash")

  if cid != manifestCid:
    return failure("Content hashes don't match!")

  return manifest.success
