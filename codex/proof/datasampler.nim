import ../contracts/requests

import std/bitops
import std/sugar

import pkg/constantine/math/arithmetic
import pkg/poseidon2/types
import pkg/poseidon2

import misc

type
  DSFieldElement* = F
  DSCellIndex* = uint64

const
  # Size of a cell.
  # A cell is a sample of storage-data selected for proving.
  CellSize* = u256(2048)

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

proc getNumberOfCellsInSlot*(slot: Slot): int =
  (slot.request.ask.slotSize div CellSize).truncate(int)

proc findCellIndex*(
  slotRootHash: DSFieldElement,
  challenge: DSFieldElement,
  counter: DSFieldElement,
  numberOfCells: int): DSCellIndex =
  # Computes the cell index for a single sample.
  let
    input = @[slotRootHash, challenge, counter]
    hash = Sponge.digest(input, rate = 2)
    index = getCellIndex(hash, numberOfCells)

  return index

func findCellIndices*(
  slot: Slot,
  slotRootHash: DSFieldElement,
  challenge: DSFieldElement,
  nSamples: int): seq[DSCellIndex] =
  # Computes nSamples cell indices.
  let numberOfCells = getNumberOfCellsInSlot(slot)
  return collect(newSeq, (for i in 1..nSamples: findCellIndex(slotRootHash, challenge, toF(i), numberOfCells)))
