import std/sequtils

import pkg/chronos
import pkg/libp2p
import pkg/libp2p/varint
import pkg/storage/blocktype
import pkg/storage/stores
import pkg/storage/manifest
import pkg/storage/merkletree
import pkg/storage/blockexchange
import pkg/storage/rng
import pkg/storage/units
import pkg/storage/utils

import ./examples
import ./helpers/nodeutils
import ./helpers/switchutils
import ./helpers/datasetutils
import ./helpers/randomchunker
import ./helpers/mockchunker
import ./helpers/mockdiscovery
import ./helpers/always
import ../checktest

export
  randomchunker, nodeutils, switchutils, datasetutils, mockdiscovery, mockchunker,
  always, checktest, manifest

export libp2p except setup, eventually

func `==`*(a, b: Block): bool =
  (a.cid == b.cid) and (a.data[] == b.data[])

proc calcEcBlocksCount*(blocksCount: int, ecK, ecM: int): int =
  let
    rounded = roundUp(blocksCount, ecK)
    steps = divUp(rounded, ecK)

  rounded + (steps * ecM)

proc lenPrefix*(msg: openArray[byte]): seq[byte] =
  ## Write `msg` with a varint-encoded length prefix
  ##

  let vbytes = PB.toBytes(msg.len().uint64)
  var buf = newSeqUninit[byte](msg.len() + vbytes.len)
  buf[0 ..< vbytes.len] = vbytes.toOpenArray()
  buf[vbytes.len ..< buf.len] = msg

  return buf

proc makeWantList*(
    treeCid: Cid,
    count: int,
    priority: int = 0,
    cancel: bool = false,
    wantType: WantType = WantType.WantHave,
    full: bool = false,
    sendDontHave: bool = false,
): WantList =
  WantList(
    entries: (0 ..< count).mapIt(
      WantListEntry(
        address: BlockAddress(treeCid: treeCid, index: it),
        priority: priority.int32,
        cancel: cancel,
        wantType: wantType,
        sendDontHave: sendDontHave,
      )
    ),
    full: full,
  )

proc testManifestDesc*(
    treeCid: Cid, blockSize: uint32, blocksCount: int
): ManifestDescriptor =
  let manifest = Manifest.new(
    treeCid = treeCid,
    blockSize = blockSize.NBytes,
    datasetSize = (blockSize.int * blocksCount).NBytes,
  )
  ManifestDescriptor(manifest: manifest, manifestCid: Cid.example)

proc storeDataGetManifest*(
    store: BlockStore, blocks: seq[Block]
): Future[ManifestDescriptor] {.async.} =
  for blk in blocks:
    (await store.putBlock(blk)).tryGet()

  let
    (_, tree, manifest, manifestCid) = makeDataset(blocks).tryGet()
    treeCid = tree.rootCid.tryGet()
    manifestBlock =
      Block.new(manifest.encode().tryGet(), codec = ManifestCodec).tryGet()

  (await store.putBlock(manifestBlock)).tryGet()

  for i in 0 ..< tree.leavesCount:
    let proof = tree.getProof(i).tryGet()
    (await store.putCidAndProof(treeCid, i, blocks[i].cid, proof)).tryGet()

  return ManifestDescriptor(manifest: manifest, manifestCid: manifestCid)

proc storeDataGetManifest*(
    store: BlockStore, chunker: Chunker
): Future[ManifestDescriptor] {.async.} =
  var blocks = newSeq[Block]()

  while (let chunk = await chunker.getBytes(); chunk.len > 0):
    blocks.add(Block.new(chunk).tryGet())

  return await storeDataGetManifest(store, blocks)

proc corruptBlocks*(
    store: BlockStore, manifest: Manifest, blks, bytes: int
): Future[seq[int]] {.async.} =
  var pos: seq[int]

  doAssert blks < manifest.blocksCount
  while pos.len < blks:
    let i = Rng.instance.rand(manifest.blocksCount - 1)
    if pos.find(i) >= 0:
      continue

    pos.add(i)
    var
      blk = (await store.getBlock(manifest.treeCid, i)).tryGet()
      bytePos: seq[int]

    doAssert bytes < blk.data[].len
    while bytePos.len <= bytes:
      let ii = Rng.instance.rand(blk.data[].len - 1)
      if bytePos.find(ii) >= 0:
        continue

      bytePos.add(ii)
      blk.data[][ii] = byte 0

  return pos
