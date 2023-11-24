import ../contracts/requests
import ../blocktype as bt
import ../merkletree
import ../manifest
import ../stores/blockstore

import std/bitops
import std/sugar

import pkg/chronicles
import pkg/chronos
import pkg/questionable
import pkg/questionable/results
import pkg/constantine/math/arithmetic
import pkg/poseidon2/types
import pkg/poseidon2

import misc
import slotblocks
import indexing
import types

func extractLowBits*[n: static int](A: BigInt[n], k: int): uint64 =
  assert(k > 0 and k <= 64)
  var r: uint64 = 0
  for i in 0..<k:
    # A is big-endian. Run index backwards: n-1-i
    #let b = bit[n](A, n-1-i)
    let b = bit[n](A, i)

    let y = uint64(b)
    if (y != 0):
      r = bitor(r, 1'u64 shl i)
  return r

proc convertToSlotCellIndex(fe: DSFieldElement, numberOfCells: int): uint64 =
  let log2 = ceilingLog2(numberOfCells)
  assert((1 shl log2) == numberOfCells , "expected `numberOfCells` to be a power of two.")

  return extractLowBits(fe.toBig(), log2)

proc getNumberOfCellsInSlot*(slot: Slot): uint64 =
  (slot.request.ask.slotSize.truncate(uint64) div CellSize)

proc findSlotCellIndex*(
  slotRootHash: DSFieldElement,
  challenge: DSFieldElement,
  counter: DSFieldElement,
  numberOfCells: uint64): DSSlotCellIndex =
  # Computes the slot-cell index for a single sample.
  let
    input = @[slotRootHash, challenge, counter]
    hash = Sponge.digest(input, rate = 2)
    index = convertToSlotCellIndex(hash, numberOfCells.int)

  return index

func findSlotCellIndices*(
  slot: Slot,
  slotRootHash: DSFieldElement,
  challenge: DSFieldElement,
  nSamples: int): seq[DSSlotCellIndex] =
  # Computes nSamples slot-cell indices.
  let numberOfCells = getNumberOfCellsInSlot(slot)
  return collect(newSeq, (for i in 1..nSamples: findSlotCellIndex(slotRootHash, challenge, toF(i), numberOfCells)))

proc getCellFromBlock*(blk: bt.Block, slotCellIndex: DSSlotCellIndex, blockSize: uint64): DSCell =
  let
    blockCellIndex = getBlockCellIndexForSlotCellIndex(slotCellIndex, blockSize)
    dataStart = (CellSize * blockCellIndex)
    dataEnd = dataStart + CellSize

  return blk.data[dataStart ..< dataEnd]

proc getBlockCells*(blk: bt.Block, blockSize: uint64): seq[DSCell] =
  let numberOfCellsPerBlock = blockSize div CellSize
  var cells: seq[DSCell]
  for i in 0..<numberOfCellsPerBlock:
    cells.add(getCellFromBlock(blk, i, blockSize))
  return cells

proc getBlockCellMiniTree*(blk: bt.Block, blockSize: uint64): ?!MerkleTree =
  without var builder =? MerkleTreeBuilder.init(): # TODO tree with poseidon2 as hasher please
    error "Failed to create merkle tree builder"
    return failure("Failed to create merkle tree builder")

  let cells = getBlockCells(blk, blockSize)
  for cell in cells:
    if builder.addDataBlock(cell).isErr:
      error "Failed to add cell data to tree"
      return failure("Failed to add cell data to tree")

  return builder.build()

proc getProofInput*(
  slot: Slot,
  blockStore: BlockStore,
  slotRootHash: DSFieldElement,
  slotPoseidonTree: MerkleTree,
  datasetToSlotProof: MerkleProof,
  challenge: DSFieldElement,
  nSamples: int
): Future[?!ProofInput] {.async.} =
  var
    slotToBlockProofs: seq[MerkleProof]
    blockToCellProofs: seq[MerkleProof]
    sampleData: seq[byte]

  without manifest =? await getManifestForSlot(slot, blockStore), err:
    error "Failed to get manifest for slot"
    return failure(err)

  let
    blockSize = manifest.blockSize.uint64
    slotCellIndices = findSlotCellIndices(slot, slotRootHash, challenge, nSamples)

  for slotCellIndex in slotCellIndices:
    let
      slotBlockIndex = getSlotBlockIndexForSlotCellIndex(slotCellIndex, blockSize)
      datasetBlockIndex = getDatasetBlockIndexForSlotBlockIndex(slot, slotBlockIndex, blockSize)

    without blk =? await getSlotBlock(slot, blockStore, manifest, slotBlockIndex), err:
      error "Failed to get slot block"
      return failure(err)

    without miniTree =? getBlockCellMiniTree(blk, blockSize), err:
      error "Failed to calculate minitree for block"
      return failure(err)

    without blockProof =? slotPoseidonTree.getProof(datasetBlockIndex), err:
      error "Failed to get dataset inclusion proof"
      return failure(err)
    slotToBlockProofs.add(blockProof)

    without cellProof =? miniTree.getProof(slotCellIndex), err:
      error "Failed to get cell inclusion proof"
      return failure(err)
    blockToCellProofs.add(cellProof)

    let cell = getCellFromBlock(blk, slotCellIndex, blockSize)
    sampleData = sampleData & cell

  trace "Successfully collected proof input data"
  success(ProofInput(
    datasetToSlotProof: datasetToSlotProof,
    slotToBlockProofs: slotToBlockProofs,
    blockToCellProofs: blockToCellProofs,
    sampleData: sampleData
  ))
