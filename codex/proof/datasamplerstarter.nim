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
    slotTreeCid*: Cid

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

proc calculateDatasetSlotProof(manifest: Manifest, slotRoots: seq[Cid], slotIndex: uint64): ?!Poseidon2Proof =
  without leafs =? convertSlotRootCidsToHashes(slotRoots), err:
    error "Failed to convert leaf Cids"
    return failure(err)

  # Todo: Duplicate of SlotBuilder.nim:166 and 212
  # -> Extract/unify top-tree creation.
  let rootsPadLeafs = newSeqWith(manifest.numSlots.nextPowerOfTwoPad, Poseidon2Zero)

  without tree =? Poseidon2Tree.init(leafs & self.rootsPadLeafs), err:
    error "Failed to calculate Dataset-SlotRoot tree"
    return failure(err)

  tree.getProof(slotIndex.int)

proc recreateSlotTree(blockStore: BlockStore, manifest: Manifest, slotTreeCid: Cid, datasetSlotIndex: uint64): Future[?!void] {.async.} =
  without expectedSlotRoot =? slotTreeCid.fromSlotCid(), err:
    error "Failed to convert slotTreeCid to hash"
    return failure(err)

  without slotBuilder =? SlotBuilder.new(blockStore, manifest), err:
    error "Failed to initialize SlotBuilder"
    return failure(err)

  without reconsturctedSlotRoot =? (await slotBuilder.buildSlot(datasetSlotIndex.int)), err:
    error "Failed to reconstruct slot tree", error = err.msg
    return failure(err)

  if not reconsturctedSlotRoot == expectedSlotRoot:
    error "Reconstructed slot root does not match manifest slot root."
    return failure("Reconstructed slot root does not match manifest slot root.")

  success()

proc ensureSlotTree(blockStore: BlockStore, manifest: Manifest, slot: Slot, slotTreeCid: Cid, datasetSlotIndex: uint64): Future[?!void] {.async.} =
  let numberOfSlotBlocks = getNumberOfBlocksInSlot(slot, manifest)

  # Do we need to check all blocks, or is [0] good enough?
  # What if a few indices are found, but a few aren't? Can that even happen?
  for slotBlockIndex in 0 ..< numberOfSlotBlocks:
    without hasTree =? (await blockStore.hasBlock(slotTreeCid, slotBlockIndex)), err:
      error "Failed to determine if slot-tree block is present in blockStore: ", error = err.msg
      return failure(err)

    if not hasTree:
      info "Slot tree not present in blockStore. Recreating..."
      return await recreateSlotTree(blockStore, manifest, slotTreeCid, datasetSlotIndex)

  success()

proc startDataSampler*(blockStore: BlockStore, manifest: Manifest, slot: Slot): Future[?!DataSamplerStarter] {.async.} =
  let
    datasetSlotIndex = slot.slotIndex.truncate(uint64)
    slotRoots = manifest.slotRoots
    slotTreeCid = manifest.slotRoots[datasetSlotIndex]

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
    slotTreeCid: slotTreeCid
  ))
