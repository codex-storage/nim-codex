import std/sequtils
import std/sugar
import std/random
import std/strutils

import pkg/questionable/results
import pkg/constantine/math/arithmetic
import pkg/constantine/math/io/io_fields
import pkg/poseidon2/io
import pkg/poseidon2
import pkg/chronos
import pkg/asynctest
import pkg/codex/stores/cachestore
import pkg/codex/chunker
import pkg/codex/stores
import pkg/codex/blocktype as bt
import pkg/codex/contracts/requests
import pkg/codex/contracts
import pkg/codex/merkletree
import pkg/codex/stores/cachestore

import pkg/codex/proof/proofselector
import pkg/codex/proof/misc
import pkg/codex/proof/types

import ../helpers
import ../examples
import ../merkletree/helpers
import ./provingtestenv

asyncchecksuite "Test proof selector":
  let knownIndices = @[90.uint64, 93.uint64, 29.uint64]

  var
    env: ProvingTestEnvironment
    proofSelector: ProofSelector

  proc createProofSelector() =
    proofSelector = ProofSelector.new(
      slot = env.slot,
      manifest = env.manifest,
      slotRootHash = env.slotRoots[datasetSlotIndex],
      cellSize = DefaultCellSize
    )

  setup:
    env = await createProvingTestEnvironment()
    createProofSelector()

  teardown:
    reset(env)
    reset(proofSelector)

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
    proc slotCellIndex(i: int): uint64 =
      let counter: Poseidon2Hash = toF(i)
      return proofSelector.findSlotCellIndex(env.challenge, counter)

    proc getExpectedIndex(i: int): uint64 =
      let
        numberOfCellsInSlot = (bytesPerBlock * numberOfSlotBlocks) div DefaultCellSize.uint64.int
        slotRootHash = env.slotTree.root().tryGet()
        hash = Sponge.digest(@[slotRootHash, env.challenge, toF(i)], rate = 2)
      return extractLowBits(hash.toBig(), ceilingLog2(numberOfCellsInSlot))

    check:
      slotCellIndex(1) == getExpectedIndex(1)
      slotCellIndex(1) == knownIndices[0]
      slotCellIndex(2) == getExpectedIndex(2)
      slotCellIndex(2) == knownIndices[1]
      slotCellIndex(3) == getExpectedIndex(3)
      slotCellIndex(3) == knownIndices[2]

  test "Can find sequence of slot-cell indices":
    proc slotCellIndices(n: int): seq[uint64]  =
      proofSelector.findSlotCellIndices(env.challenge, n)

    proc getExpectedIndices(n: int): seq[uint64]  =
      return collect(newSeq, (for i in 1..n: proofSelector.findSlotCellIndex(env.challenge, toF(i))))

    check:
      slotCellIndices(3) == getExpectedIndices(3)
      slotCellIndices(3) == knownIndices

  for (input, expected) in [(10, 0), (31, 0), (32, 1), (63, 1), (64, 2)]:
    test "Can get slotBlockIndex from slotCellIndex (" & $input & " -> " & $expected & ")":
      let
        slotCellIndex = input.uint64
        slotBlockIndex = proofSelector.getSlotBlockIndexForSlotCellIndex(slotCellIndex)

      check:
        slotBlockIndex == expected.uint64

  for (input, expected) in [(10, 10), (31, 31), (32, 0), (63, 31), (64, 0)]:
    test "Can get blockCellIndex from slotCellIndex (" & $input & " -> " & $expected & ")":
      let
        slotCellIndex = input.uint64
        blockCellIndex = proofSelector.getBlockCellIndexForSlotCellIndex(slotCellIndex)

      check:
        blockCellIndex == expected.uint64
