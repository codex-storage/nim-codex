import pkg/chronos
import pkg/libp2p except setup
import pkg/libp2p/varint
import pkg/codex/blocktype as bt
import pkg/codex/stores
import pkg/codex/manifest
import pkg/codex/rng

import ./helpers/nodeutils
import ./helpers/randomchunker
import ./helpers/mockdiscovery
import ./helpers/eventually
import ../checktest

export randomchunker, nodeutils, mockdiscovery, eventually, checktest, manifest

export libp2p except setup

# NOTE: The meaning of equality for blocks
# is changed here, because blocks are now `ref`
# types. This is only in tests!!!
func `==`*(a, b: bt.Block): bool =
  (a.cid == b.cid) and (a.data == b.data)

proc lenPrefix*(msg: openArray[byte]): seq[byte] =
  ## Write `msg` with a varint-encoded length prefix
  ##

  let vbytes = PB.toBytes(msg.len().uint64)
  var buf = newSeqUninitialized[byte](msg.len() + vbytes.len)
  buf[0..<vbytes.len] = vbytes.toOpenArray()
  buf[vbytes.len..<buf.len] = msg

  return buf

proc corruptBlocks*(
    store: BlockStore,
    manifest: Manifest,
    blks, bytes: int
): Future[seq[int]] {.async.} =
  var pos: seq[int]

  doAssert blks < manifest.len
  while pos.len < blks:
    let i = Rng.instance.rand(manifest.len - 1)
    if pos.find(i) >= 0:
      continue

    pos.add(i)
    var
      blk = (await store.getBlock(manifest[i])).tryGet()
      bytePos: seq[int]

    doAssert bytes < blk.data.len
    while bytePos.len <= bytes:
      let ii = Rng.instance.rand(blk.data.len - 1)
      if bytePos.find(ii) >= 0:
        continue

      bytePos.add(ii)
      blk.data[ii] = byte 0
  return pos
