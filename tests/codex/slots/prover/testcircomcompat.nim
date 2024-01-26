
import std/json
import std/sequtils
import std/sugar

import pkg/chronos
import pkg/asynctest

import pkg/codex/slots
import pkg/codex/slots/types
import pkg/codex/merkletree

import pkg/constantine/math/arithmetic
import pkg/constantine/math/io/io_fields
import pkg/constantine/math/io/io_bigints

suite "Test Backend":
  test "Should verify with known input":
    let
      r1cs = "tests/codex/slots/prover/fixtures/proof_main.r1cs"
      wasm = "tests/codex/slots/prover/fixtures/proof_main.wasm"
      zkey = "tests/codex/slots/prover/fixtures/proof_main.zkey"
      inputData = readFile("tests/codex/slots/prover/fixtures/input.json")
      inputJson = parseJson(inputData)
      samples = collect(newSeq):
        for i in 0..<5:
          let
            cellData = inputJson["cellData"][i].mapIt(
              block:
                var
                  big: BigInt[254]
                  data = newSeq[byte](big.bits div 8)
                check bool(big.fromDecimal( it.str ))
                data.marshal(big, littleEndian)
                data
              ).concat

            merklePaths = inputJson["merklePaths"][0].mapIt(
              block:
                var
                  big: BigInt[254]
                  hash: Poseidon2Hash
                check bool(big.fromDecimal( it.str ))
                hash.fromBig( big )
                hash
            )

          Sample[Poseidon2Hash](
            data: cellData,
            merkleProof: merklePaths)

    let
      slotProof = inputJson["slotProof"].mapIt(
        block:
          var
            big: BigInt[254]
            hash: Poseidon2Hash
          check bool(big.fromDecimal( it.str ))
          hash.fromBig( big )
          hash
        )

      datasetRoot = block:
        var
          big: BigInt[254]
          hash: Poseidon2Hash
        check bool(big.fromDecimal( inputJson["dataSetRoot"].str ))
        hash.fromBig( big )
        hash

      slotRoot = block:
        var
          big: BigInt[254]
          hash: Poseidon2Hash
        check bool(big.fromDecimal( inputJson["slotRoot"].str ))
        hash.fromBig( big )
        hash

      entropy = block:
        var
          big: BigInt[254]
          hash: Poseidon2Hash
        check bool(big.fromDecimal( inputJson["entropy"].str ))
        hash.fromBig( big )
        hash

      nCellsPerSlot = inputJson["nCellsPerSlot"].getInt
      nSlotsPerDataSet = inputJson["nSlotsPerDataSet"].getInt
      slotIndex = inputJson["slotIndex"].getInt

      proofInput = ProofInput[Poseidon2Hash](
        entropy: entropy,
        slotIndex: slotIndex,
        verifyRoot: datasetRoot,
        verifyProof: slotProof,
        numCells: nCellsPerSlot,
        numSlots: nSlotsPerDataSet,
        samples: samples)

    var
      backend = CircomCompat[Poseidon2Hash, Proof].new(r1cs, wasm)

    let
      proof: Proof = (await backend.prove(proofInput)).tryGet

    check (await backend.verify(proof)).tryGet

    backend.release()
