import std/bitops
import std/sugar

import pkg/chronicles
import pkg/chronos
import pkg/questionable
import pkg/questionable/results
import pkg/constantine/math/arithmetic
import pkg/poseidon2
import pkg/poseidon2/io
import pkg/libp2p
import pkg/stew/arrayops

import misc
import slotblocks
import types
import datasamplerstarter
import proofpadding
import proofblock
import proofselector
import ../contracts/requests
import ../blocktype as bt
import ../merkletree
import ../manifest
import ../stores/blockstore
import ../slots/converters
import ../utils/poseidon2digest

# Index naming convention:
# "<ContainerType><ElementType>Index" => The index of an ElementType within a ContainerType.
# Some examples:
# SlotBlockIndex => The index of a Block within a Slot.
# DatasetBlockIndex => The index of a Block within a Dataset.

logScope:
  topics = "codex datasampler"

type
  DataSampler* = ref object of RootObj
    slot: Slot
    blockStore: BlockStore
    slotBlocks: SlotBlocks
    # The following data is invariant over time for a given slot:
    datasetRoot: Poseidon2Hash
    slotRootHash: Poseidon2Hash
    slotTreeCid: Cid
    datasetToSlotProof: Poseidon2Proof
    padding: ProofPadding
    blockSize: uint64
    datasetSlotIndex: uint64
    proofSelector: ProofSelector

proc new*(
    T: type DataSampler,
    slot: Slot,
    blockStore: BlockStore
): DataSampler =
  # Create a DataSampler for a slot.
  # A DataSampler can create the input required for the proving circuit.
  DataSampler(
    slot: slot,
    blockStore: blockStore
  )

proc start*(self: DataSampler): Future[?!void] {.async.} =
  let slotBlocks = SlotBlocks.new(
    self.slot.slotIndex,
    self.slot.request.content.cid,
    self.blockStore)
  if err =? (await slotBlocks.start()).errorOption:
    error "Failed to create SlotBlocks object for slot", error = err.msg
    return failure(err)

  let
    manifest = slotBlocks.manifest
    blockSize = manifest.blockSize.uint64

  without starter =? (await startDataSampler(self.blockStore, manifest, self.slot)), e:
    error "Failed to start data sampler", error = e.msg
    return failure(e)

  without datasetRoot =? manifest.verifyRoot.fromProvingCid(), e:
    error "Failed to convert manifest verification root to Poseidon2Hash", error = e.msg
    return failure(e)

  without slotRootHash =? starter.slotTreeCid.fromSlotCid(), e:
    error "Failed to convert slot cid to hash", error = e.msg
    return failure(e)

  self.slotBlocks = slotBlocks
  self.datasetRoot = datasetRoot
  self.slotRootHash = slotRootHash
  self.slotTreeCid = starter.slotTreeCid
  self.datasetToSlotProof = starter.datasetToSlotProof
  self.padding = starter.padding
  self.blockSize = blockSize
  self.datasetSlotIndex = starter.datasetSlotIndex

  self.proofSelector = ProofSelector.new(
    slot = self.slot,
    manifest = manifest,
    slotRootHash = slotRootHash,
    cellSize = DefaultCellSize
  )
  success()

proc getCellFromBlock*(self: DataSampler, blk: bt.Block, slotCellIndex: uint64): Cell =
  let
    blockCellIndex = self.proofSelector.getBlockCellIndexForSlotCellIndex(slotCellIndex)
    dataStart = (DefaultCellSize.uint64 * blockCellIndex)
    dataEnd = dataStart + DefaultCellSize.uint64
  return blk.data[dataStart ..< dataEnd]

proc getSlotBlockProof(self: DataSampler, slotBlockIndex: uint64): Future[?!Poseidon2Proof] {.async.} =
  without (cid, proof) =? (await self.blockStore.getCidAndProof(self.slotTreeCid, slotBlockIndex.int)), err:
    error "Unable to load cid and proof", error = err.msg
    return failure(err)

  without poseidon2Proof =? proof.toVerifiableProof(), err:
    error "Unable to convert proof", error = err.msg
    return failure(err)

  return success(poseidon2Proof)

proc createProofSample(self: DataSampler, slotCellIndex: uint64) : Future[?!ProofSample] {.async.} =
  let
    slotBlockIndex = self.proofSelector.getSlotBlockIndexForSlotCellIndex(slotCellIndex)
    blockCellIndex = self.proofSelector.getBlockCellIndexForSlotCellIndex(slotCellIndex)

  without blockProof =? (await self.getSlotBlockProof(slotBlockIndex)), err:
    error "Failed to get slot-to-block inclusion proof", error = err.msg
    return failure(err)

  without blk =? await self.slotBlocks.getSlotBlock(slotBlockIndex), err:
    error "Failed to get slot block", error = err.msg
    return failure(err)

  without proofBlock =? ProofBlock.new(self.padding, blk, DefaultCellSize), err:
    error "Failed to create proof block", error = err.msg
    return failure(err)

  without cellProof =? proofBlock.proof(blockCellIndex.int), err:
    error "Failed to get block-to-cell inclusion proof", error = err.msg
    return failure(err)

  let cell = self.getCellFromBlock(blk, slotCellIndex)

  return success(ProofSample(
    cellData: cell,
    slotBlockIndex: slotBlockIndex,
    blockSlotProof: blockProof,
    blockCellIndex: blockCellIndex,
    cellBlockProof: cellProof
  ))

proc getProofInput*(self: DataSampler, challenge: array[32, byte], nSamples: int): Future[?!ProofInput] {.async.} =
  var samples: seq[ProofSample]
  without entropy =? Poseidon2Hash.fromBytes(challenge), err:
    error "Failed to convert challenge bytes to Poseidon2Hash", error = err.msg
    return failure(err)

  let slotCellIndices = self.proofSelector.findSlotCellIndices(entropy, nSamples)

  trace "Collecing input for proof", selectedSlotCellIndices = $slotCellIndices
  for slotCellIndex in slotCellIndices:
    without sample =? await self.createProofSample(slotCellIndex), err:
      error "Failed to create proof sample", error = err.msg
      return failure(err)
    samples.add(sample)

  trace "Successfully collected proof input"
  success(ProofInput(
    datasetRoot: self.datasetRoot,
    entropy: entropy,
    numberOfCellsInSlot: self.proofSelector.numberOfCellsInSlot,
    numberOfSlots: self.slot.request.ask.slots,
    datasetSlotIndex: self.datasetSlotIndex,
    slotRoot: self.slotRootHash,
    datasetToSlotProof: self.datasetToSlotProof,
    proofSamples: samples
  ))
