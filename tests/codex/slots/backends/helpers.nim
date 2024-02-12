
import std/sequtils
import std/sugar
import std/strutils

import pkg/poseidon2
import pkg/constantine/math/arithmetic
import pkg/constantine/math/io/io_bigints
import pkg/constantine/math/io/io_fields

import pkg/codex/merkletree
import pkg/codex/slots
import pkg/codex/slots/types
import pkg/codex/utils/json

export types

func fromCircomData*[H](cellData: seq[byte]): seq[H] =
  var
    pos = 0
    cellElms: seq[Bn254Fr]
  while pos < cellData.len:
    var
      step = 32
      offset = min(pos + step, cellData.len)
      data = cellData[pos..<offset]
    let ff = Bn254Fr.fromBytes(data.toArray32).get
    cellElms.add(ff)
    pos += data.len

  cellElms

func toPublicInputs*[H](input: ProofInputs[H]): PublicInputs[H] =
  PublicInputs[H](
    slotIndex: input.slotIndex,
    datasetRoot: input.datasetRoot,
    entropy: input.entropy
  )

func toJsonDecimal*(big: BigInt[254]): string =
  let s = big.toDecimal.strip( leading = true, trailing = false, chars = {'0'} )
  if s.len == 0: "0" else: s

func toJson*[H](input: ProofInputs[H]): JsonNode =
  var
    input = input

  %* {
    "dataSetRoot": input.datasetRoot.toBig.toJsonDecimal,
    "entropy": input.entropy.toBig.toJsonDecimal,
    "nCellsPerSlot": input.nCellsPerSlot,
    "nSlotsPerDataSet": input.nSlotsPerDataSet,
    "slotIndex": input.slotIndex,
    "slotRoot": input.slotRoot.toDecimal,
    "slotProof": input.slotProof.mapIt( it.toBig.toJsonDecimal ),
    "cellData": input.samples.mapIt(
      toSeq( it.cellData.elements(H) ).mapIt( it.toBig.toJsonDecimal )
    ),
    "merklePaths": input.samples.mapIt(
      it.merklePaths.mapIt( it.toBig.toJsonDecimal )
    )
  }

func jsonToProofInput*[H](inputJson: JsonNode): ProofInputs[H] =
  let
    cellData =
      inputJson["cellData"].mapIt(
          it.mapIt(
            block:
              var
                big: BigInt[256]
                data = newSeq[byte](big.bits div 8)
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
                hash: H
              assert bool(big.fromDecimal( it.getStr ))
              hash.fromBig( big )
              hash
          )
        )

    slotProof = inputJson["slotProof"].mapIt(
      block:
        var
          big: BigInt[254]
          hash: H
        assert bool(big.fromDecimal( it.str ))
        hash.fromBig( big )
        hash
      )

    datasetRoot = block:
      var
        big: BigInt[254]
        hash: H
      assert bool(big.fromDecimal( inputJson["dataSetRoot"].str ))
      hash.fromBig( big )
      hash

    slotRoot = block:
      var
        big: BigInt[254]
        hash: H
      assert bool(big.fromDecimal( inputJson["slotRoot"].str ))
      hash.fromBig( big )
      hash

    entropy = block:
      var
        big: BigInt[254]
        hash: H
      assert bool(big.fromDecimal( inputJson["entropy"].str ))
      hash.fromBig( big )
      hash

    nCellsPerSlot = inputJson["nCellsPerSlot"].getInt
    nSlotsPerDataSet = inputJson["nSlotsPerDataSet"].getInt
    slotIndex = inputJson["slotIndex"].getInt

  ProofInputs[H](
    entropy: entropy,
    slotIndex: slotIndex,
    datasetRoot: datasetRoot,
    slotProof: slotProof,
    slotRoot: slotRoot,
    nCellsPerSlot: nCellsPerSlot,
    nSlotsPerDataSet: nSlotsPerDataSet,
    samples: zip(cellData, merklePaths)
      .mapIt(Sample[H](
        cellData: it[0],
        merklePaths: it[1]
      ))
  )
