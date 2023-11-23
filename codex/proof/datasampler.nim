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

const
  # Size of a cell.
  # A cell is a sample of storage-data selected for proving.
  CellSize* = 2048.uint64

type
  DSFieldElement* = F
  DSCellIndex* = uint64
  DSCell* = seq[byte]
  ProofInput* = ref object
    blockInclProofs*: seq[MerkleProof]
    cellInclProofs*: seq[MerkleProof]
    sampleData*: seq[byte]

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

proc getCellIndex(fe: DSFieldElement, numberOfCells: int): uint64 =
  let log2 = ceilingLog2(numberOfCells)
  assert((1 shl log2) == numberOfCells , "expected `numberOfCells` to be a power of two.")

  return extractLowBits(fe.toBig(), log2)

proc getNumberOfCellsInSlot*(slot: Slot): uint64 =
  (slot.request.ask.slotSize.truncate(uint64) div CellSize)

proc findCellIndex*(
  slotRootHash: DSFieldElement,
  challenge: DSFieldElement,
  counter: DSFieldElement,
  numberOfCells: uint64): DSCellIndex =
  # Computes the cell index for a single sample.
  let
    input = @[slotRootHash, challenge, counter]
    hash = Sponge.digest(input, rate = 2)
    index = getCellIndex(hash, numberOfCells.int)

  return index

func findCellIndices*(
  slot: Slot,
  slotRootHash: DSFieldElement,
  challenge: DSFieldElement,
  nSamples: int): seq[DSCellIndex] =
  # Computes nSamples cell indices.
  let numberOfCells = getNumberOfCellsInSlot(slot)
  return collect(newSeq, (for i in 1..nSamples: findCellIndex(slotRootHash, challenge, toF(i), numberOfCells)))

proc getSlotBlockIndex*(cellIndex: DSCellIndex, blockSize: uint64): uint64 =
  let numberOfCellsPerBlock = blockSize div CellSize
  return cellIndex div numberOfCellsPerBlock

proc getDatasetBlockIndex*(slot: Slot, slotBlockIndex: uint64, blockSize: uint64): uint64 =
  let
    slotIndex = slot.slotIndex.truncate(uint64)
    slotSize = slot.request.ask.slotSize.truncate(uint64)
    blocksInSlot = slotSize div blockSize

  return (blocksInSlot * slotIndex) + slotBlockIndex

proc getCellIndexInBlock*(cellIndex: DSCellIndex, blockSize: uint64): uint64 =
  let numberOfCellsPerBlock = blockSize div CellSize
  return cellIndex mod numberOfCellsPerBlock

proc getCellFromBlock*(blk: bt.Block, cellIndex: DSCellIndex, blockSize: uint64): DSCell =
  let
    inBlockCellIndex = getCellIndexInBlock(cellIndex, blockSize)
    dataStart = (CellSize * inBlockCellIndex)
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
  dataSetPoseidonTree: MerkleTree,
  challenge: DSFieldElement,
  nSamples: int
): Future[?!ProofInput] {.async.} =
  var
    blockProofs: seq[MerkleProof]
    cellProofs: seq[MerkleProof]
    sampleData: seq[byte]

  without manifest =? await getManifestForSlot(slot, blockStore), err:
    error "Failed to get manifest for slot"
    return failure(err)

  let
    blockSize = manifest.blockSize.uint64
    cellIndices = findCellIndices(slot, slotRootHash, challenge, nSamples)

  for cellIndex in cellIndices:
    let slotBlockIndex = getSlotBlockIndex(cellIndex, blockSize)
    without blk =? await getSlotBlock(slot, blockStore, manifest, slotBlockIndex), err:
      error "Failed to get slot block"
      return failure(err)

    without miniTree =? getBlockCellMiniTree(blk, blockSize), err:
      error "Failed to calculate minitree for block"
      return failure(err)

    # without blockProof =? dataSetPoseidonTree.getProof(???block index in dataset!), err:
    #   error "Failed to get dataset inclusion proof"
    #   return failure(err)
    # blockProofs.add(blockProof)

    without cellProof =? miniTree.getProof(cellIndex), err:
      error "Failed to get cell inclusion proof"
      return failure(err)
    cellProofs.add(cellProof)

    let cell = getCellFromBlock(blk, cellIndex, blockSize)
    sampleData = sampleData & cell

  trace "Successfully collected proof input data"
  success(ProofInput(
    blockInclProofs: blockProofs,
    cellInclProofs: cellProofs,
    sampleData: sampleData
  ))
