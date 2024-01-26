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
import pkg/nimcrypto
import pkg/codex/stores/cachestore
import pkg/codex/chunker
import pkg/codex/stores
import pkg/codex/blocktype as bt
import pkg/codex/contracts/requests
import pkg/codex/contracts
import pkg/codex/merkletree
import pkg/codex/stores/cachestore

import pkg/codex/slots/sampler
import pkg/codex/slots/builder/builder

import ../helpers
import ../examples
import ../merkletree/helpers
import testsampler_expected
import ./provingtestenv

asyncchecksuite "Test DataSampler":
  var
    env: ProvingTestEnvironment
    dataSampler: DataSampler
    blk: bt.Block
    cell0Bytes: seq[byte]
    cell1Bytes: seq[byte]
    cell2Bytes: seq[byte]

  proc createDataSampler(): Future[void] {.async.} =
    dataSampler = DataSampler.new(
      datasetSlotIndex,
      env.localStore,
      SlotsBuilder.new(env.localStore, env.manifest).tryGet()).tryGet()

  setup:
    randomize()
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
      sample0 = dataSampler.getCell(blk.data, 0)
      sample1 = dataSampler.getCell(blk.data, 1)
      sample2 = dataSampler.getCell(blk.data, 2)

    check:
      sample0 == cell0Bytes
      sample1 == cell1Bytes
      sample2 == cell2Bytes

  test "Can gather proof input":
    let
      nSamples = 3
      challengeBytes = env.challengeNoPad.toBytes()
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
      equal(input.verifyRoot, env.datasetRootHash)
      equal(input.entropy, env.challengeNoPad)
      input.numCells == ((bytesPerBlock * numberOfSlotBlocks) div DefaultCellSize.int).Natural
      input.numSlots == totalNumberOfSlots.Natural
      input.slotIndex == env.slot.slotIndex.truncate(Natural)
      input.verifyProof == expectedProof

      # block-slot proofs
      input.samples[0].slotBlockIdx == 1
      input.samples[1].slotBlockIdx == 2
      input.samples[2].slotBlockIdx == 1
      toStr(input.samples[0].slotProof) == expectedBlockSlotProofs[0]
      toStr(input.samples[1].slotProof) == expectedBlockSlotProofs[1]
      toStr(input.samples[2].slotProof) == expectedBlockSlotProofs[2]

      # cell-block proofs
      input.samples[0].blockCellIdx == 25
      input.samples[1].blockCellIdx == 18
      input.samples[2].blockCellIdx == 17
      toStr(input.samples[0].cellProof) == expectedCellBlockProofs[0]
      toStr(input.samples[1].cellProof) == expectedCellBlockProofs[1]
      toStr(input.samples[2].cellProof) == expectedCellBlockProofs[2]

      # cell data
      nimcrypto.toHex(input.samples[0].data) == expectedCellData[0]
      nimcrypto.toHex(input.samples[1].data) == expectedCellData[1]
      nimcrypto.toHex(input.samples[2].data) == expectedCellData[2]

  test "Can select samples in padded cells":
    let
      nSamples = 3
      challengeBytes = env.challengeOnePad.toBytes()
      input = (await dataSampler.getProofInput(challengeBytes, nSamples)).tryget()

    proc equal(a: Poseidon2Hash, b: Poseidon2Hash): bool =
      a.toDecimal() == b.toDecimal()

    proc toStr(proof: Poseidon2Proof): string =
      let a = proof.path.mapIt(toHex(it))
      join(a)

    let expectedProof = env.datasetToSlotTree.getProof(datasetSlotIndex).tryGet()

    check:
      equal(input.verifyRoot, env.datasetRootHash)
      equal(input.entropy, env.challengeOnePad)
      input.numCells == ((bytesPerBlock * numberOfSlotBlocks) div DefaultCellSize.int).Natural
      input.numSlots == totalNumberOfSlots.Natural
      input.slotIndex == env.slot.slotIndex.truncate(Natural)
      input.verifyProof == expectedProof

      input.samples[0].slotBlockIdx == 2
      input.samples[1].slotBlockIdx == 2
      input.samples[2].slotBlockIdx == 3
      # The third sample is a padded sample
      toStr(input.samples[2].slotProof) == toStr(env.slotTree.getProof(3).tryGet())

      input.samples[0].blockCellIdx == 29
      input.samples[1].blockCellIdx == 26
      input.samples[2].blockCellIdx == 30
      toStr(input.samples[2].cellProof) == toStr(env.emptyBlockTree.getProof(30).tryGet())

      input.samples[2].data == newSeq[byte](DefaultCellSize.int)
