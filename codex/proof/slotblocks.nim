import std/sequtils
import std/sugar

import pkg/chronos
import pkg/chronicles
import pkg/libp2p
import pkg/questionable
import pkg/questionable/results
import pkg/upraises

import ../contracts/requests
import ../stores/blockstore
import ../manifest
import ../indexingstrategy
import ../node/batch
import ../utils

type
  SlotBlocks* = ref object of RootObj
    slotIndex: uint64
    contentCid: string
    blockStore: BlockStore
    manifest: Manifest
    datasetBlockIndices: seq[int]

const
  DefaultFetchBatchSize = 200

proc getManifestForSlot(self: SlotBlocks): Future[?!Manifest] {.async.} =
  without manifestBlockCid =? Cid.init(self.contentCid).mapFailure, err:
    error "Unable to init CID from slot request content cid"
    return failure err

  without manifestBlock =? await self.blockStore.getBlock(manifestBlockCid), err:
    error "Failed to fetch manifest block", cid = manifestBlockCid
    return failure err

  without manifest =? Manifest.decode(manifestBlock):
    error "Unable to decode manifest"
    return failure("Unable to decode manifest")

  return success(manifest)

proc new*(
    T: type SlotBlocks,
    slotIndex: UInt256,
    contentCid: string,
    blockStore: BlockStore
): SlotBlocks =
  SlotBlocks(
    slotIndex: slotIndex.truncate(uint64),
    contentCid: contentCid,
    blockStore: blockStore
  )

proc start*(self: SlotBlocks, strategy: IndexingStrategy = nil): Future[?!void] {.async.} =
  # Create a SlotBlocks object for a slot.
  # SlotBlocks lets you get the manifest of a slot and blocks by slotBlockIndex for a slot.
  without manifest =? await self.getManifestForSlot():
    error "Failed to get manifest for slot"
    return failure("Failed to get manifest for slot")
  self.manifest = manifest

  let strategy = if strategy == nil:
      SteppedIndexingStrategy.new(
        0, manifest.blocksCount - 1, manifest.numSlots)
      else:
        strategy
  self.datasetBlockIndices = strategy.getIndicies(self.slotIndex.int)
  success()

proc manifest*(self: SlotBlocks): Manifest =
  self.manifest

proc getDatasetBlockIndexForSlotBlockIndex*(self: SlotBlocks, slotBlockIndex: uint64): ?!int =
  if slotBlockIndex.int >= self.datasetBlockIndices.len:
    return failure("slotBlockIndex is out-of-range: " & $slotBlockIndex)
  return success(self.datasetBlockIndices[slotBlockIndex])

proc getSlotBlock*(self: SlotBlocks, slotBlockIndex: uint64): Future[?!Block] {.async.} =
  without datasetBlockIndex =? self.getDatasetBlockIndexForSlotBlockIndex(slotBlockIndex), err:
    return failure(err)

  return await self.blockStore.getBlock(self.manifest.treeCid, datasetBlockIndex)

proc fetchBlocksBatched*(
  self: SlotBlocks,
  batchSize = DefaultFetchBatchSize,
  onBatch: BatchProc = nil): Future[?!void] {.async, gcsafe.} =
  let
    numSlotBlocks = divUp(self.manifest.blocksCount, self.manifest.numSlots)
    batchCount = divUp(numSlotBlocks, batchSize)
  trace "Fetching slot blocks in batches", batchSize, numSlotBlocks

  let iter = Iter.fromSlice(0 ..< self.manifest.blocksCount)
    .map((i: int) => self.getSlotBlock(i.uint64))

  for batchNum in 0 ..< batchCount:
    let blocks = collect:
      for i in 0 ..< batchSize:
        if not iter.finished:
          iter.next()

    if blocksErr =? (await allFutureResult(blocks)).errorOption:
      return failure(blocksErr)

    if not onBatch.isNil and batchErr =? (await onBatch(blocks.mapIt( it.read.get ))).errorOption:
      return failure(batchErr)

  return success()
