import std/sequtils

import pkg/chronos
import pkg/libp2p
import pkg/libp2p/varint
import pkg/codex/blocktype
import pkg/codex/stores
import pkg/codex/manifest
import pkg/codex/merkletree
import pkg/codex/blockexchange
import pkg/codex/rng

import ./helpers/nodeutils
import ./helpers/randomchunker
import ./helpers/mockchunker
import ./helpers/mockdiscovery
import ./helpers/always
import ../checktest

export randomchunker, nodeutils, mockdiscovery, mockchunker, always, checktest, manifest

export libp2p except setup, eventually

# NOTE: The meaning of equality for blocks
# is changed here, because blocks are now `ref`
# types. This is only in tests!!!
func `==`*(a, b: Block): bool =
  (a.cid == b.cid) and (a.data == b.data)

proc lenPrefix*(msg: openArray[byte]): seq[byte] =
  ## Write `msg` with a varint-encoded length prefix
  ##

  let vbytes = PB.toBytes(msg.len().uint64)
  var buf = newSeqUninitialized[byte](msg.len() + vbytes.len)
  buf[0..<vbytes.len] = vbytes.toOpenArray()
  buf[vbytes.len..<buf.len] = msg

  return buf

proc makeManifestAndTree*(blocks: seq[Block]): ?!(Manifest, MerkleTree) =

  if blocks.len == 0:
    return failure("Blocks list was empty")

  let 
    mcodec = (? blocks[0].cid.mhash.mapFailure).mcodec
    datasetSize = blocks.mapIt(it.data.len).foldl(a + b)
    blockSize = blocks.mapIt(it.data.len).foldl(max(a, b))

  var builder = ? MerkleTreeBuilder.init(mcodec)

  for b in blocks:
    let mhash = ? b.cid.mhash.mapFailure
    if mhash.mcodec != mcodec:
      return failure("Blocks are not using the same codec")
    ? builder.addLeaf(mhash)

  let 
    tree = ? builder.build()
    treeBlk = ? Block.new(tree.encode())
    manifest = Manifest.new(
      treeCid = treeBlk.cid,
      treeRoot = tree.root,
      blockSize = NBytes(blockSize),
      datasetSize = NBytes(datasetSize),
      version = CIDv1,
      hcodec = mcodec
    )

  return success((manifest, tree))

proc makeWantList*(
    cids: seq[Cid],
    priority: int = 0,
    cancel: bool = false,
    wantType: WantType = WantType.WantHave,
    full: bool = false,
    sendDontHave: bool = false
  ): WantList =
    WantList(
      entries: cids.mapIt(
        WantListEntry(
          address: BlockAddress(leaf: false, cid: it),
          priority: priority.int32,
          cancel: cancel,
          wantType: wantType,
          sendDontHave: sendDontHave) ),
      full: full)

proc storeDataGetManifest*(store: BlockStore, chunker: Chunker): Future[Manifest] {.async.} =
  var builder = MerkleTreeBuilder.init().tryGet()

  while (
    let chunk = await chunker.getBytes();
    chunk.len > 0):

    let blk = Block.new(chunk).tryGet()
    # builder.addDataBlock(blk.data).tryGet()
    let mhash = blk.cid.mhash.mapFailure.tryGet()
    builder.addLeaf(mhash).tryGet()
    (await store.putBlock(blk)).tryGet()

  let
    tree = builder.build().tryGet()
    treeBlk = Block.new(tree.encode()).tryGet()

  let manifest = Manifest.new(
    treeCid = treeBlk.cid,
    treeRoot = tree.root,
    blockSize = NBytes(chunker.chunkSize),
    datasetSize = NBytes(chunker.offset),
  )

  (await store.putBlock(treeBlk)).tryGet()

  return manifest

proc corruptBlocks*(
  store: BlockStore,
  manifest: Manifest,
  blks, bytes: int): Future[seq[int]] {.async.} =
  var pos: seq[int]

  doAssert blks < manifest.blocksCount
  while pos.len < blks:
    let i = Rng.instance.rand(manifest.blocksCount - 1)
    if pos.find(i) >= 0:
      continue

    pos.add(i)
    var
      blk = (await store.getBlock(manifest.treeCid, i, manifest.treeRoot)).tryGet()
      bytePos: seq[int]

    doAssert bytes < blk.data.len
    while bytePos.len <= bytes:
      let ii = Rng.instance.rand(blk.data.len - 1)
      if bytePos.find(ii) >= 0:
        continue

      bytePos.add(ii)
      blk.data[ii] = byte 0
  return pos
