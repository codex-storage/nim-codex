import std/sequtils
import std/sugar
import std/random
import std/strutils
import std/math

import pkg/questionable/results
import pkg/constantine/math/arithmetic
import pkg/constantine/math/io/io_fields
import pkg/poseidon2/io
import pkg/poseidon2
import pkg/chronos
import pkg/asynctest/chronos/unittest
import pkg/codex/stores/cachestore
import pkg/codex/chunker
import pkg/codex/stores
import pkg/codex/blocktype as bt
import pkg/codex/contracts/requests
import pkg/codex/contracts
import pkg/codex/merkletree
import pkg/codex/stores/cachestore

import pkg/codex/slots/sampler/utils

import ../helpers
import ../examples
import ../merkletree/helpers
import ./provingtestenv

asyncchecksuite "Test proof sampler utils":
  let knownIndices: seq[Natural] = @[57, 82, 49]

  var
    env: ProvingTestEnvironment
    slotRoot: Poseidon2Hash
    numCells: Natural
    numCellsPadded: Natural

  setup:
    env = await createProvingTestEnvironment()
    slotRoot = env.slotRoots[datasetSlotIndex]
    numCells = cellsPerSlot
    numCellsPadded = numCells.nextPowerOfTwo

  teardown:
    reset(env)

  test "Extract low bits":
    proc extract(value: uint64, nBits: int): uint64 =
      let big = toF(value).toBig()
      return extractLowBits(big, nBits)

    check:
      extract(0x88, 4) == 0x8.uint64
      extract(0x88, 7) == 0x8.uint64
      extract(0x9A, 5) == 0x1A.uint64
      extract(0x9A, 7) == 0x1A.uint64
      extract(0x1248, 10) == 0x248.uint64
      extract(0x1248, 12) == 0x248.uint64
      extract(0x1248306A560C9AC0.uint64, 10) == 0x2C0.uint64
      extract(0x1248306A560C9AC0.uint64, 12) == 0xAC0.uint64
      extract(0x1248306A560C9AC0.uint64, 50) == 0x306A560C9AC0.uint64
      extract(0x1248306A560C9AC0.uint64, 52) == 0x8306A560C9AC0.uint64

  test "Can find single slot-cell index":
    proc slotCellIndex(i: Natural): Natural =
      return cellIndex(env.challengeNoPad, slotRoot, numCellsPadded, i)

    proc getExpectedIndex(i: int): Natural =
      let
        numberOfCellsInSlot = (bytesPerBlock * numberOfSlotBlocks) div DefaultCellSize.uint64.int
        numberOfCellsInSlotPadded = numberOfCellsInSlot.nextPowerOfTwo
        hash = Sponge.digest(@[slotRoot, env.challengeNoPad, toF(i)], rate = 2)

      return int(extractLowBits(hash.toBig(), ceilingLog2(numberOfCellsInSlotPadded)))

    check:
      slotCellIndex(1) == getExpectedIndex(1)
      slotCellIndex(1) == knownIndices[0]
      slotCellIndex(2) == getExpectedIndex(2)
      slotCellIndex(2) == knownIndices[1]
      slotCellIndex(3) == getExpectedIndex(3)
      slotCellIndex(3) == knownIndices[2]

  test "Can find sequence of slot-cell indices":
    proc slotCellIndices(n: int): seq[Natural]  =
      cellIndices(env.challengeNoPad, slotRoot, numCellsPadded, n)

    proc getExpectedIndices(n: int): seq[Natural]  =
      return collect(newSeq, (for i in 1..n: cellIndex(env.challengeNoPad, slotRoot, numCellsPadded, i)))

    check:
      slotCellIndices(3) == getExpectedIndices(3)
      slotCellIndices(3) == knownIndices

  for (input, expected) in [(10, 0), (31, 0), (32, 1), (63, 1), (64, 2)]:
    test "Can get slotBlockIndex from slotCellIndex (" & $input & " -> " & $expected & ")":
      let slotBlockIndex = toBlockIdx(input, numCells = 32)

      check:
        slotBlockIndex == expected

  for (input, expected) in [(10, 10), (31, 31), (32, 0), (63, 31), (64, 0)]:
    test "Can get blockCellIndex from slotCellIndex (" & $input & " -> " & $expected & ")":
      let blockCellIndex = toBlockCellIdx(input, numCells = 32)

      check:
        blockCellIndex == expected
