import pkg/chronos
import pkg/chronicles
import pkg/libp2p
import pkg/questionable
import pkg/questionable/results

import ../contracts/requests
import ../stores/blockstore
import ../manifest
import ../indexingstrategy

type
  SlotBlocks* = ref object of RootObj
    slot: Slot
    blockStore: BlockStore
    manifest: Manifest
    datasetBlockIndices: seq[int]

proc getManifestForSlot(slot: Slot, blockStore: BlockStore): Future[?!Manifest] {.async.} =
  without manifestBlockCid =? Cid.init(slot.request.content.cid).mapFailure, err:
    error "Unable to init CID from slot.content.cid"
    return failure err

  without manifestBlock =? await blockStore.getBlock(manifestBlockCid), err:
    error "Failed to fetch manifest block", cid = manifestBlockCid
    return failure err

  without manifest =? Manifest.decode(manifestBlock):
    error "Unable to decode manifest"
    return failure("Unable to decode manifest")

  return success(manifest)

proc new*(
    T: type SlotBlocks,
    slot: Slot,
    blockStore: BlockStore,
    strategy: IndexingStrategy = nil
): Future[?!SlotBlocks] {.async.} =
  # Create a SlotBlocks object for a slot.
  # SlotBlocks lets you get the manifest of a slot and blocks by slotBlockIndex for a slot.
  without manifest =? await getManifestForSlot(slot, blockStore):
    error "Failed to get manifest for slot"
    return failure("Failed to get manifest for slot")

  let
    strategy = if strategy == nil:
      SteppedIndexingStrategy.new(
        0, manifest.blocksCount - 1, manifest.numSlots)
      else:
        strategy
    datasetBlockIndices = strategy.getIndicies(slot.slotIndex.truncate(uint64).int)

  success(SlotBlocks(
    slot: slot,
    blockStore: blockStore,
    manifest: manifest,
    datasetBlockIndices: datasetBlockIndices
  ))

proc manifest*(self: SlotBlocks): Manifest =
  self.manifest

proc getDatasetBlockIndexForSlotBlockIndex*(self: SlotBlocks, slotBlockIndex: uint64): int =
  return self.datasetBlockIndices[slotBlockIndex]

proc getSlotBlock*(self: SlotBlocks, slotBlockIndex: uint64): Future[?!Block] {.async.} =
  let
    blocksInManifest = (self.manifest.datasetSize div self.manifest.blockSize).int
    datasetBlockIndex = self.getDatasetBlockIndexForSlotBlockIndex(slotBlockIndex)

  if datasetBlockIndex >= blocksInManifest:
    return failure("Found datasetBlockIndex that is out-of-range: " & $datasetBlockIndex)

  return await self.blockStore.getBlock(self.manifest.treeCid, datasetBlockIndex)
