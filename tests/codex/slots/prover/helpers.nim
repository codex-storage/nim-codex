
import std/json
import std/sequtils

import pkg/poseidon2
import pkg/constantine/math/arithmetic
import pkg/constantine/math/io/io_bigints

import pkg/codex/merkletree
import pkg/codex/slots/types

type
  Input* = object
    cellData*: seq[seq[byte]]
    merklePaths*: seq[seq[Poseidon2Hash]]
    slotProof*: seq[Poseidon2Hash]
    datasetRoot*: Poseidon2Hash
    slotRoot*: Poseidon2Hash
    entropy*: Poseidon2Hash
    nCellsPerSlot*: int
    nSlotsPerDataSet*: int
    slotIndex*: int

proc toInput*(inputJson: JsonNode): Input =
  let
    cellData =
      inputJson["cellData"].mapIt(
          it.mapIt(
            block:
              var
                big: BigInt[256]
                data = newSeq[byte](BigInt[256].bits div 8)
              assert bool(big.fromDecimal( it.str ))
              data.marshal(big, littleEndian)
              data
          ).concat # flatten out elements
        )

    merklePaths =
        inputJson["merklePaths"].mapIt(
          it.mapIt(
            block:
              var
                big: BigInt[254]
                hash: Poseidon2Hash
              assert bool(big.fromDecimal( it.str ))
              hash.fromBig( big )
              hash
          )
        )

    slotProof = inputJson["slotProof"].mapIt(
      block:
        var
          big: BigInt[254]
          hash: Poseidon2Hash
        assert bool(big.fromDecimal( it.str ))
        hash.fromBig( big )
        hash
      )

    datasetRoot = block:
      var
        big: BigInt[254]
        hash: Poseidon2Hash
      assert bool(big.fromDecimal( inputJson["dataSetRoot"].str ))
      hash.fromBig( big )
      hash

    slotRoot = block:
      var
        big: BigInt[254]
        hash: Poseidon2Hash
      assert bool(big.fromDecimal( inputJson["slotRoot"].str ))
      hash.fromBig( big )
      hash

    entropy = block:
      var
        big: BigInt[254]
        hash: Poseidon2Hash
      assert bool(big.fromDecimal( inputJson["entropy"].str ))
      hash.fromBig( big )
      hash

    nCellsPerSlot = inputJson["nCellsPerSlot"].getInt
    nSlotsPerDataSet = inputJson["nSlotsPerDataSet"].getInt
    slotIndex = inputJson["slotIndex"].getInt

  Input(
    cellData: cellData,
    merklePaths: merklePaths,
    slotProof: slotProof,
    datasetRoot: datasetRoot,
    slotRoot: slotRoot,
    entropy: entropy,
    nCellsPerSlot: nCellsPerSlot,
    nSlotsPerDataSet: nSlotsPerDataSet,
    slotIndex: slotIndex)

proc toProofInput*[H](input: Input): ProofInput[H] =
    ProofInput[H](
      entropy: input.entropy,
      slotIndex: input.slotIndex,
      verifyRoot: input.datasetRoot,
      verifyProof: input.slotProof,
      slotRoot: input.slotRoot,
      numCells: input.nCellsPerSlot,
      numSlots: input.nSlotsPerDataSet,
      samples: zip(input.cellData, input.merklePaths)
        .mapIt(Sample[H](
          data: it[0],
          merkleProof: it[1]
        ))
    )
