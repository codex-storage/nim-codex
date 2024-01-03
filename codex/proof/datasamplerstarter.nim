import std/sequtils
import pkg/libp2p
import pkg/chronicles
import pkg/chronos
import pkg/questionable
import pkg/questionable/results

import ../contracts/requests
import ../blocktype as bt
import ../merkletree
import ../manifest
import ../stores/blockstore
import ../slots/converters
import ../slots/slotbuilder

type
  DataSamplerStarter* = object of RootObj
    datasetSlotIndex*: uint64
    datasetToSlotProof*: Poseidon2Proof
    slotPoseidonTree*: Poseidon2Tree

proc getNumberOfBlocksInSlot*(slot: Slot, manifest: Manifest): uint64 =
  let blockSize = manifest.blockSize.uint64
  (slot.request.ask.slotSize.truncate(uint64) div blockSize)

proc rollUp[T](input: seq[?!T]): ?!seq[T] =
  var output = newSeq[T]()
  for element in input:
    if element.isErr:
      return failure(element.error)
    else:
      output.add(element.get())
  return success(output)

proc convertSlotRootCidsToHashes(slotRoots: seq[Cid]): ?!seq[Poseidon2Hash] =
  rollUp(slotRoots.mapIt(it.fromSlotCid()))

proc calculateDatasetSlotProof(slotRoots: seq[Cid], slotIndex: uint64): ?!Poseidon2Proof =
  without leafs =? convertSlotRootCidsToHashes(slotRoots), err:
    error "Failed to convert leaf Cids"
    return failure(err)

  without tree =? Poseidon2Tree.init(leafs), err:
    error "Failed to calculate Dataset-SlotRoot tree"
    return failure(err)

  tree.getProof(slotIndex.int)

proc recreateSlotTree(blockStore: BlockStore, manifest: Manifest, datasetSlotIndex: uint64): Future[?!Poseidon2Tree] {.async.} =
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
      error "Error when loading cid and proof from blockStore: ", error = err.msg
      warn "Failed to load slot tree from blockStore. Recreating..."
      return await recreateSlotTree(blockStore, manifest, datasetSlotIndex)

  # TODO: Build a tree out of these proofs somehow!
  raiseAssert("building tree from proofs not implemented???")

proc startDataSampler*(blockStore: BlockStore, manifest: Manifest, slot: Slot): Future[?!DataSamplerStarter] {.async.} =
  let
    datasetSlotIndex = slot.slotIndex.truncate(uint64)
    slotRoots = manifest.slotRoots

  trace "Initializing data sampler", datasetSlotIndex

  without datasetToSlotProof =? calculateDatasetSlotProof(slotRoots, datasetSlotIndex), err:
    error "Failed to calculate dataset-slot inclusion proof"
    return failure(err)

  without slotPoseidonTree =? await ensureSlotTree(blockStore, manifest, slot, datasetSlotIndex), err:
    error "Failed to load or recreate slot tree"
    return failure(err)

  success(DataSamplerStarter(
    datasetSlotIndex: datasetSlotIndex,
    datasetToSlotProof: datasetToSlotProof,
    slotPoseidonTree: slotPoseidonTree
  ))
