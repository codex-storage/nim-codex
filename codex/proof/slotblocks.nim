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

proc getManifestForSlot*(slot: Slot, blockstore: BlockStore): Future[?!Manifest] {.async.} =
  without manifestBlockCid =? Cid.init(slot.request.content.cid).mapFailure, err:
    error "Unable to init CID from slot.content.cid"
    return failure err

  without manifestBlock =? await blockstore.getBlock(manifestBlockCid), err:
    error "Failed to fetch manifest block", cid = manifestBlockCid
    return failure err

  without manifest =? Manifest.decode(manifestBlock):
    error "Unable to decode manifest"
    return failure("Unable to decode manifest")

  return success(manifest)

proc getIndexForSlotBlock*(slot: Slot, blockSize: NBytes, slotBlockIndex: int): uint64 =
  let
    slotSize = slot.request.ask.slotSize.truncate(uint64)
    blocksInSlot = slotSize div blockSize.uint64
    slotIndex = slot.slotIndex.truncate(uint64)

    datasetIndex = (slotIndex * blocksInSlot) + slotBlockIndex.uint64

  trace "Converted slotBlockIndex to datasetIndex", slotBlockIndex, datasetIndex
  return datasetIndex

proc getSlotBlock*(slot: Slot, blockstore: BlockStore, slotBlockIndex: int): Future[?!Block] {.async.} =
  without manifest =? (await getManifestForSlot(slot, blockstore)), err:
    error "Failed to get manifest for slot"
    return failure(err)

  let
    blocksInManifest = (manifest.datasetSize div manifest.blockSize).uint64
    datasetIndex = getIndexForSlotBlock(slot, manifest.blockSize, slotBlockIndex)

  if datasetIndex >= blocksInManifest:
    return failure("Found slotBlockIndex that is out-of-range: " & $datasetIndex)

  return await blockstore.getBlock(manifest.treeCid, datasetIndex)
