import std/sequtils
import pkg/chronos
import pkg/asynctest
import pkg/questionable/results
import pkg/codex/blocktype as bt
import pkg/codex/rng
import pkg/codex/stores
import pkg/codex/chunker
import pkg/codex/merkletree

import ../helpers

import codex/slotbuilder/slotbuilder

asyncchecksuite "Slot builder":
  let
    blockSize = 64 * 1024
    numberOfSlotBlocks = 6
    numberOfSlots = 5
    datasetSize = numberOfSlotBlocks * numberOfSlots * blockSize
    chunker = RandomChunker.new(Rng.instance(), size = datasetSize, chunkSize = blockSize)

  var
    datasetBlocks: seq[bt.Block]
    localStore = CacheStore.new()
    protectedManifest: Manifest
    slotBuilder: SlotBuilder

  proc createBlocks(): Future[void] {.async.} =
    while true:
      let chunk = await chunker.getBytes()
      if chunk.len <= 0:
        break
      let blk = bt.Block.new(chunk).tryGet()
      datasetBlocks.add(blk)
      discard await localStore.putBlock(blk)

  proc createProtectedManifest(): Future[void] {.async.} =
    let
      cids = datasetBlocks.mapIt(it.cid)
      tree = MerkleTree.init(cids).tryGet()
      treeCid = tree.rootCid().tryGet()

    for index, cid in cids:
      let proof = tree.getProof(index).tryget()
      discard await localStore.putBlockCidAndProof(treeCid, index, cid, proof)

    protectedManifest = Manifest.new(
      manifest = Manifest.new(
        treeCid = treeCid,
        blockSize = blockSize.NBytes,
        datasetSize = datasetSize.NBytes),
      treeCid = treeCid,
      datasetSize = datasetSize.NBytes,
      ecK = numberOfSlots,
      ecM = 0
    )

    let manifestBlock = bt.Block.new(protectedManifest.encode().tryGet(), codec = DagPBCodec).tryGet()
    discard await localStore.putBlock(manifestBlock)

  setup:
    await createBlocks()
    await createProtectedManifest()
    slotBuilder = SlotBuilder.new(localStore, protectedManifest)

  for i in 0 ..< numberOfSlots:
    test "Can get the protected slot blocks given a slot index (" & $i & ")":
      let
        selectStart = i * numberOfSlotBlocks
        selectEnd = selectStart + numberOfSlotBlocks
        expectedCids = datasetBlocks.mapIt(it.cid)[selectStart ..< selectEnd]
        cids = slotBuilder.getSlotBlockCids(i.uint64)

      check:
        cids == expectedCids
