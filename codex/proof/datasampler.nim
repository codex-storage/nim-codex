import ../contracts/requests
import ../blocktype as bt
import ../merkletree
import ../manifest
import ../stores/blockstore

import std/bitops
import std/sugar
import std/sequtils

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

# Index naming convention:
# "<ContainerType><ElementType>Index" => The index of an ElementType within a ContainerType.
# Some examples:
# SlotBlockIndex => The index of a Block within a Slot.
# DatasetBlockIndex => The index of a Block within a Dataset.

logScope:
  topics = "codex datasampler"

proc toCid*(pHash: Poseidon2Hash, mcodec: MultiCodec): Cid =
  let mhash = MultiHash.init(multiCodec("poseidon2-alt_bn_128-merkle-2kb"), pHash.toBytes()).tryGet()
  return Cid.init(CIDv1, mcodec, mhash).tryGet()

proc toPoseidon2Hash*(cid: Cid): ?!Poseidon2Hash =
  if cid.cidver != CIDv1:
    return failure("Unexpected CID version")

  if cid.mcodec != multiCodec("poseidon2-alt_bn_128-merkle-2kb"):
    return failure("CID is not a poseidon2-alt_bn_128-merkle-2kb")

  let
    bytes: array[32, byte] = array[32, byte].initCopyFrom(cid.data.buffer)
    hash = Poseidon2Hash.fromBytes(bytes)
  if not hash.isSome():
    return failure("Unable to convert CID to Poseidon2Hash")
  return success(hash.get())

type
  DataSampler* = object of RootObj
    slot: Slot
    blockStore: BlockStore
    slotBlocks: SlotBlocks
    # The following data is invariant over time for a given slot:
    datasetRoot: Poseidon2Hash
    slotRootHash: Poseidon2Hash
    slotPoseidonTree: Poseidon2Tree
    datasetToSlotProof: Poseidon2Proof
    blockSize: uint64
    numberOfCellsInSlot: uint64
    datasetSlotIndex: uint64
    numberOfCellsPerBlock: uint64

proc getNumberOfCellsInSlot*(slot: Slot): uint64 =
  (slot.request.ask.slotSize.truncate(uint64) div DefaultCellSize.uint64)

proc new*(
    T: type DataSampler,
    slot: Slot,
    blockStore: BlockStore,
    datasetRoot: Poseidon2Hash,
    slotPoseidonTree: Poseidon2Tree,
    datasetToSlotProof: Poseidon2Proof
): Future[?!DataSampler] {.async.} =
  # Create a DataSampler for a slot.
  # A DataSampler can create the input required for the proving circuit.
  without slotBlocks =? await SlotBlocks.new(slot, blockStore):
    error "Failed to create SlotBlocks object for slot"
    return failure("Failed to create SlotBlocks object for slot")

  let
    numberOfCellsInSlot = getNumberOfCellsInSlot(slot)
    blockSize = slotBlocks.manifest.blockSize.uint64

  success(DataSampler(
    slot: slot,
    blockStore: blockStore,
    slotBlocks: slotBlocks,
    datasetRoot: datasetRoot,
    slotRootHash: slotPoseidonTree.root(),
    slotPoseidonTree: slotPoseidonTree,
    datasetToSlotProof: datasetToSlotProof,
    blockSize: blockSize,
    numberOfCellsInSlot: numberOfCellsInSlot,
    datasetSlotIndex: slot.slotIndex.truncate(uint64),
    numberOfCellsPerBlock: blockSize div DefaultCellSize.uint64
  ))

func extractLowBits*[n: static int](A: BigInt[n], k: int): uint64 =
  assert(k > 0 and k <= 64)
  var r: uint64 = 0
  for i in 0..<k:
    let b = bit[n](A, i)

    let y = uint64(b)
    if (y != 0):
      r = bitor(r, 1'u64 shl i)
  return r

proc convertToSlotCellIndex(self: DataSampler, fe: Poseidon2Hash): uint64 =
  let
    n = self.numberOfCellsInSlot.int
    log2 = ceilingLog2(n)
  assert((1 shl log2) == n , "expected `numberOfCellsInSlot` to be a power of two.")

  return extractLowBits(fe.toBig(), log2)

func getSlotBlockIndexForSlotCellIndex*(self: DataSampler, slotCellIndex: uint64): uint64 =
  return slotCellIndex div self.numberOfCellsPerBlock

func getBlockCellIndexForSlotCellIndex*(self: DataSampler, slotCellIndex: uint64): uint64 =
  return slotCellIndex mod self.numberOfCellsPerBlock

proc findSlotCellIndex*(self: DataSampler, challenge: Poseidon2Hash, counter: Poseidon2Hash): uint64 =
  # Computes the slot-cell index for a single sample.
  let
    input = @[self.slotRootHash, challenge, counter]
    hash = Sponge.digest(input, rate = 2)
  return convertToSlotCellIndex(self, hash)

func findSlotCellIndices*(self: DataSampler, challenge: Poseidon2Hash, nSamples: int): seq[uint64] =
  # Computes nSamples slot-cell indices.
  return collect(newSeq, (for i in 1..nSamples: self.findSlotCellIndex(challenge, toF(i))))

proc getCellFromBlock*(self: DataSampler, blk: bt.Block, slotCellIndex: uint64): Cell =
  let
    blockCellIndex = self.getBlockCellIndexForSlotCellIndex(slotCellIndex)
    dataStart = (DefaultCellSize.uint64 * blockCellIndex)
    dataEnd = dataStart + DefaultCellSize.uint64
  return blk.data[dataStart ..< dataEnd]

proc getBlockCells*(self: DataSampler, blk: bt.Block): seq[Cell] =
  var cells: seq[Cell]
  for i in 0 ..< self.numberOfCellsPerBlock:
    cells.add(self.getCellFromBlock(blk, i))
  return cells

proc getBlockCellMiniTree*(self: DataSampler, blk: bt.Block): ?!Poseidon2Tree =
  let
    cells = self.getBlockCells(blk)
    cellHashes = cells.mapIt(Sponge.digest(it, rate = 2))

  return Poseidon2Tree.init(cellHashes)

proc createProofSample(self: DataSampler, slotCellIndex: uint64) : Future[?!ProofSample] {.async.} =
  let
    slotBlockIndex = self.getSlotBlockIndexForSlotCellIndex(slotCellIndex)
    blockCellIndex = self.getBlockCellIndexForSlotCellIndex(slotCellIndex)

  without blk =? await self.slotBlocks.getSlotBlock(slotBlockIndex), err:
    error "Failed to get slot block"
    return failure(err)

  without miniTree =? self.getBlockCellMiniTree(blk), err:
    error "Failed to calculate minitree for block"
    return failure(err)

  # Should getProof(index) be a uint64?
  without blockProof =? self.slotPoseidonTree.getProof(slotBlockIndex.int), err:
    error "Failed to get slot-to-block inclusion proof"
    return failure(err)

  without cellProof =? miniTree.getProof(blockCellIndex.int), err:
    error "Failed to get block-to-cell inclusion proof"
    return failure(err)

  let cell = self.getCellFromBlock(blk, slotCellIndex)

  return success(ProofSample(
    cellData: cell,
    slotBlockIndex: slotBlockIndex,
    blockSlotProof: blockProof,
    blockCellIndex: blockCellIndex,
    cellBlockProof: cellProof
  ))

proc getProofInput*(self: DataSampler, challenge: Poseidon2Hash, nSamples: int): Future[?!ProofInput] {.async.} =
  var samples: seq[ProofSample]
  let slotCellIndices = self.findSlotCellIndices(challenge, nSamples)

  trace "Collecing input for proof", selectedSlotCellIndices = $slotCellIndices
  for slotCellIndex in slotCellIndices:
    without sample =? await self.createProofSample(slotCellIndex), err:
      error "Failed to create proof sample"
      return failure(err)
    samples.add(sample)

  trace "Successfully collected proof input"
  success(ProofInput(
    datasetRoot: self.datasetRoot,
    entropy: challenge,
    numberOfCellsInSlot: self.numberOfCellsInSlot,
    numberOfSlots: self.slot.request.ask.slots,
    datasetSlotIndex: self.datasetSlotIndex,
    slotRoot: self.slotRootHash,
    datasetToSlotProof: self.datasetToSlotProof,
    proofSamples: samples
  ))
