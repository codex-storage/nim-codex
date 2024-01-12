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
import ../slots/builder
import ./proofpadding

type
  DataSamplerStarter* = object of RootObj
    datasetSlotIndex*: uint64
    datasetToSlotProof*: Poseidon2Proof
    slotTreeCid*: Cid

proc getNumberOfBlocksInSlot*(slot: Slot, manifest: Manifest): uint64 =
  let blockSize = manifest.blockSize.uint64
  (slot.request.ask.slotSize.truncate(uint64) div blockSize)

# This shouldn't be necessary... is it? Should it be in utils?
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

proc calculateDatasetSlotProof(manifest: Manifest, slotRoots: seq[Cid], slotIndex: uint64): ?!Poseidon2Proof =
  without leafs =? convertSlotRootCidsToHashes(slotRoots), err:
    error "Failed to convert leaf Cids", error = err.msg
    return failure(err)

  # Todo: Duplicate of SlotBuilder.nim:166 and 212
  # -> Extract/unify top-tree creation.
  let rootsPadLeafs = newSeqWith(manifest.numSlots.nextPowerOfTwoPad, Poseidon2Zero)

  without tree =? Poseidon2Tree.init(leafs & rootsPadLeafs), err:
    error "Failed to calculate Dataset-SlotRoot tree", error = err.msg
    return failure(err)

  without reconstructedDatasetRoot =? tree.root(), err:
    error "Failed to get reconstructed dataset root tree", error = err.msg
    return failure(err)

  without expectedDatasetRoot =? manifest.verifyRoot.fromProvingCid(), err:
    error "Failed to decode verification root from manifest", error = err.msg
    return failure(err)

  if reconstructedDatasetRoot != expectedDatasetRoot:
    error "Reconstructed dataset root does not match manifest dataset root."
    return failure("Reconstructed dataset root does not match manifest dataset root.")

  tree.getProof(slotIndex.int)

proc recreateSlotTree(blockStore: BlockStore, manifest: Manifest, slotTreeCid: Cid, datasetSlotIndex: uint64): Future[?!void] {.async.} =
  without expectedSlotRoot =? slotTreeCid.fromSlotCid(), err:
    error "Failed to convert slotTreeCid to hash", error = err.msg
    return failure(err)

  without slotsBuilder =? SlotsBuilder.new(blockStore, manifest), err:
    error "Failed to initialize SlotBuilder", error = err.msg
    return failure(err)

  without reconstructedSlotRoot =? (await slotsBuilder.buildSlot(datasetSlotIndex.int)), err:
    error "Failed to reconstruct slot tree", error = err.msg
    return failure(err)

  if reconstructedSlotRoot != expectedSlotRoot:
    error "Reconstructed slot root does not match manifest slot root."
    return failure("Reconstructed slot root does not match manifest slot root.")

  success()

proc ensureSlotTree(blockStore: BlockStore, manifest: Manifest, slot: Slot, slotTreeCid: Cid, datasetSlotIndex: uint64): Future[?!void] {.async.} =
  let numberOfSlotBlocks = getNumberOfBlocksInSlot(slot, manifest)

  # Do we need to check all blocks, or is [0] good enough?
  # What if a few indices are found, but a few aren't? Can that even happen?
  for slotBlockIndex in 0 ..< numberOfSlotBlocks:
    without (cid, proof) =? (await blockStore.getCidAndProof(slotTreeCid, slotBlockIndex)), err:
      info "Slot tree not present in blockStore. Recreating..."
      return await recreateSlotTree(blockStore, manifest, slotTreeCid, datasetSlotIndex)

  success()

proc startDataSampler*(blockStore: BlockStore, manifest: Manifest, slot: Slot): Future[?!DataSamplerStarter] {.async.} =
  trace "Initializing data sampler", slotIndex = slot.slotIndex

  if not manifest.protected or not manifest.verifiable:
    return failure("Can only create DataSampler using verifiable manifests.")

  let
    datasetSlotIndex = slot.slotIndex.truncate(uint64)
    slotRoots = manifest.slotRoots
    slotTreeCid = manifest.slotRoots[datasetSlotIndex]

  without datasetToSlotProof =? calculateDatasetSlotProof(manifest, slotRoots, datasetSlotIndex), err:
    error "Failed to calculate dataset-slot inclusion proof", error = err.msg
    return failure(err)

  if err =? (await ensureSlotTree(blockStore, manifest, slot, slotTreeCid, datasetSlotIndex)).errorOption:
    error "Failed to load or recreate slot tree", error = err.msg
    return failure(err)

  success(DataSamplerStarter(
    datasetSlotIndex: datasetSlotIndex,
    datasetToSlotProof: datasetToSlotProof,
    slotTreeCid: slotTreeCid
  ))
