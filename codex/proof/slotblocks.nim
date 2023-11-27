import std/bitops
import std/sugar

import pkg/chronos
import pkg/chronicles
import pkg/libp2p
import pkg/questionable
import pkg/questionable/results

import ../contracts/requests
import ../stores/blockstore
import ../manifest

type
  SlotBlocks* = ref object of RootObj
    slot: Slot
    blockStore: BlockStore
    manifest: Manifest

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
    blockStore: BlockStore
): Future[?!SlotBlocks] {.async.} =
  # Create a SlotBlocks object for a slot.
  # SlotBlocks lets you get the manifest of a slot and blocks by slotBlockIndex for a slot.
  without manifest =? await getManifestForSlot(slot, blockStore):
    error "Failed to get manifest for slot"
    return failure("Failed to get manifest for slot")

  success(SlotBlocks(
    slot: slot,
    blockStore: blockStore,
    manifest: manifest
  ))

proc manifest*(self: SlotBlocks): Manifest =
  self.manifest

proc getDatasetBlockIndexForSlotBlockIndex*(self: SlotBlocks, slotBlockIndex: uint64): uint64 =
  let
    slotSize = self.slot.request.ask.slotSize.truncate(uint64)
    blocksInSlot = slotSize div self.manifest.blockSize.uint64
    datasetSlotIndex = self.slot.slotIndex.truncate(uint64)
  return (datasetSlotIndex * blocksInSlot) + slotBlockIndex

proc getSlotBlock*(self: SlotBlocks, slotBlockIndex: uint64): Future[?!Block] {.async.} =
  let
    blocksInManifest = (self.manifest.datasetSize div self.manifest.blockSize).uint64
    datasetBlockIndex = self.getDatasetBlockIndexForSlotBlockIndex(slotBlockIndex)

  if datasetBlockIndex >= blocksInManifest:
    return failure("Found datasetBlockIndex that is out-of-range: " & $datasetBlockIndex)

  return await self.blockStore.getBlock(self.manifest.treeCid, datasetBlockIndex)
