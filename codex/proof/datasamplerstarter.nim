import ../contracts/requests
import ../blocktype as bt
import ../merkletree
import ../manifest
import ../stores/blockstore

import pkg/chronicles
import pkg/chronos
import pkg/questionable
import pkg/questionable/results

type
  DataSamplerStarter* = object of RootObj
    datasetSlotIndex*: uint64
    datasetToSlotProof*: Poseidon2Proof
    slotPoseidonTree*: Poseidon2Tree

proc getNumberOfBlocksInSlot*(slot: Slot, manifest: Manifest): uint64 =
  let blockSize = manifest.blockSize.uint64
  (slot.request.ask.slotSize.truncate(uint64) div blockSize)

proc calculateDatasetSlotProof(slotRoots: seq[Cid], slotIndex: uint64): ?!Poseidon2Proof =
  let leafs = slotRoots # To poseidon hashes!
  without tree =? Poseidon2Tree.init(leafs), err:
    error "Failed to calculate Dataset-SlotRoot tree"
    return failure(err)

  tree.getProof(slotIndex.int)

proc recreateSlotTree(blockStore: BlockStore, manifest: Manifest): Future[?!Poseidon2Tree] {.async.} =
  without slotBuilder =? SlotBuilder.new(blockStore, manifest), err:
    error "Failed to initialize SlotBuilder"
    return failure(err)

  await slotBuilder.buildSlotTree(datasetSlotIndex.int)

proc ensureSlotTree(blockStore: BlockStore, manifest: Manifest, slot: Slot, datasetSlotIndex: uint64): Future[?!Poseidon2Tree] {.async.} =
  let
    numberOfSlotBlocks = getNumberOfBlocksInSlot(slot, manifest)
    slotCid = manifest.slotRoots[datasetSlotIndex]

  for blockIndex in 0 ..< numberOfSlotBlocks:
    without (blockCid, proof) =? await blockStore.getCidAndProof(slotCid, blockIndex), err:
      error "Error when loading cid and proof from blockStore: " & $err
      warn "Failed to load slot tree from blockStore. Recreating..."
      return await recreateSlotTree(blockStore, manifest)

  # TODO: Build a tree out of these proofs somehow!
  raiseAssert("building tree from proofs not implemented???")

proc startDataSampler*(blockStore: BlockStore, manifest: Manifest, slot: Slot): Future[?!DataSamplerStarter] {.async.} =
  let
    datasetSlotIndex = slot.slotIndex.truncate(uint64)
    slotRoots = manifest.slotRoots

  trace "Initializing data sampler", datasetSlotIndex

  without datasetSlotProof =? calculateDatasetSlotProof(slotRoots, datasetSlotIndex), err:
    error "Failed to calculate dataset-slot inclusion proof"
    return failure(err)

  without slotPoseidonTree =? ensureSlotTree(blockStore, manifest, slot, datasetSlotIndex), err:
    error "Failed to load or recreate slot tree"
    return failure(err)

  success(DataSamplerStarter(
    datasetSlotIndex: datasetSlotIndex
    datasetToSlotProof: datasetToSlotProof
    slotPoseidonTree: slotPoseidonTree
  ))
