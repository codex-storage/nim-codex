import ../contracts/requests
import ../blocktype as bt
import ../merkletree

import std/bitops
import std/sugar

import pkg/chronicles
import pkg/questionable
import pkg/questionable/results
import pkg/constantine/math/arithmetic
import pkg/poseidon2/types
import pkg/poseidon2

import misc

const
  # Size of a cell.
  # A cell is a sample of storage-data selected for proving.
  CellSize* = 2048.uint64

type
  DSFieldElement* = F
  DSCellIndex* = uint64
  DSCell* = seq[byte]


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
