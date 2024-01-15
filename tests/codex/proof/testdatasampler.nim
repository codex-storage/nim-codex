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

import pkg/codex/proof/datasampler
import pkg/codex/proof/misc
import pkg/codex/proof/types

import ../helpers
import ../examples
import ../merkletree/helpers
import testdatasampler_expected
import ./provingtestenv

asyncchecksuite "Test proof datasampler":
  var
    env: ProvingTestEnvironment
    dataSampler: DataSampler
    blk: bt.Block
    cell0Bytes: seq[byte]
    cell1Bytes: seq[byte]
    cell2Bytes: seq[byte]

  proc createDataSampler(): Future[void] {.async.} =
    dataSampler = DataSampler.new(
      env.slot,
      env.localStore
    )
    (await dataSampler.start()).tryGet()

  setup:
    env = await createProvingTestEnvironment()
    let bytes = newSeqWith(bytesPerBlock, rand(uint8))
    blk = bt.Block.new(bytes).tryGet()
    cell0Bytes = bytes[0..<DefaultCellSize.uint64]
    cell1Bytes = bytes[DefaultCellSize.uint64..<(DefaultCellSize.uint64*2)]
    cell2Bytes = bytes[(DefaultCellSize.uint64*2)..<(DefaultCellSize.uint64*3)]

    await createDataSampler()

  teardown:
    reset(env)
    reset(dataSampler)

  test "Can get cell from block":
    let
      sample0 = dataSampler.getCellFromBlock(blk, 0)
      sample1 = dataSampler.getCellFromBlock(blk, 1)
      sample2 = dataSampler.getCellFromBlock(blk, 2)

    check:
      sample0 == cell0Bytes
      sample1 == cell1Bytes
      sample2 == cell2Bytes

  test "Can gather proof input":
    let
      nSamples = 3
      challengeBytes = env.challenge.toBytes()
      input = (await dataSampler.getProofInput(challengeBytes, nSamples)).tryget()

    proc equal(a: Poseidon2Hash, b: Poseidon2Hash): bool =
      a.toDecimal() == b.toDecimal()

    proc toStr(proof: Poseidon2Proof): string =
      let a = proof.path.mapIt(toHex(it))
      join(a)

    let
      expectedBlockSlotProofs = getExpectedBlockSlotProofs()
      expectedCellBlockProofs = getExpectedCellBlockProofs()
      expectedCellData = getExpectedCellData()
      expectedProof = env.datasetToSlotTree.getProof(datasetSlotIndex).tryGet()

    check:
      equal(input.datasetRoot, env.datasetRootHash)
      equal(input.entropy, env.challenge)
      input.numberOfCellsInSlot == (bytesPerBlock * numberOfSlotBlocks).uint64 div DefaultCellSize.uint64
      input.numberOfSlots == env.slot.request.ask.slots
      input.datasetSlotIndex == env.slot.slotIndex.truncate(uint64)
      equal(input.slotRoot, env.slotTree.root().tryGet())
      input.datasetToSlotProof == expectedProof

      # block-slot proofs
      input.proofSamples[0].slotBlockIndex == 2
      input.proofSamples[1].slotBlockIndex == 2
      input.proofSamples[2].slotBlockIndex == 0
      toStr(input.proofSamples[0].blockSlotProof) == expectedBlockSlotProofs[0]
      toStr(input.proofSamples[1].blockSlotProof) == expectedBlockSlotProofs[1]
      toStr(input.proofSamples[2].blockSlotProof) == expectedBlockSlotProofs[2]

      # cell-block proofs
      input.proofSamples[0].blockCellIndex == 26
      input.proofSamples[1].blockCellIndex == 29
      input.proofSamples[2].blockCellIndex == 29
      toStr(input.proofSamples[0].cellBlockProof) == expectedCellBlockProofs[0]
      toStr(input.proofSamples[1].cellBlockProof) == expectedCellBlockProofs[1]
      toStr(input.proofSamples[2].cellBlockProof) == expectedCellBlockProofs[2]

      # cell data
      toHex(input.proofSamples[0].cellData) == expectedCellData[0]
      toHex(input.proofSamples[1].cellData) == expectedCellData[1]
      toHex(input.proofSamples[2].cellData) == expectedCellData[2]
