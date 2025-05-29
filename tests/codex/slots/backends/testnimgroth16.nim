import std/options
import std/isolation

import ../../../asynctest

import pkg/chronos
import pkg/poseidon2
import pkg/serde/json
import pkg/taskpools

import pkg/codex/slots {.all.}
import pkg/codex/slots/types {.all.}
import pkg/codex/merkletree
import pkg/codex/merkletree/poseidon2
import pkg/codex/codextypes
import pkg/codex/manifest
import pkg/codex/stores

import pkg/groth16
import pkg/nim/circom_witnessgen
import pkg/nim/circom_witnessgen/load
import pkg/nim/circom_witnessgen/witness

import ./helpers
import ../helpers
import ../../helpers

suite "Test NimGoth16 Backend - control inputs":
  let
    graph = "tests/circuits/fixtures/proof_main.bin"
    r1cs = "tests/circuits/fixtures/proof_main.r1cs"
    zkey = "tests/circuits/fixtures/proof_main.zkey"

  var
    nimGroth16: NimGroth16BackendRef
    proofInputs: ProofInputs[Poseidon2Hash]

  setup:
    let
      inputData = readFile("tests/circuits/fixtures/input.json")
      inputJson = !JsonNode.parse(inputData)

    proofInputs = Poseidon2Hash.jsonToProofInput(inputJson)
    nimGroth16 = NimGroth16BackendRef.new(graph, r1cs, zkey, tp = Taskpool.new()).tryGet

  teardown:
    nimGroth16.release()

  test "Should verify with correct inputs":
    let proof = (await nimGroth16.prove(proofInputs)).tryGet
    check (await nimGroth16.verify(proof)).tryGet

#   test "Should not verify with incorrect inputs":
#     proofInputs.slotIndex = 1 # change slot index

#     let proof = (await nimGroth16.prove(proofInputs)).tryGet
#     check (await nimGroth16.verify(proof)).tryGet == false

# suite "Test NimGoth16 Backend":
#   let
#     ecK = 2
#     ecM = 2
#     slotId = 3
#     samples = 5
#     numDatasetBlocks = 8
#     blockSize = DefaultBlockSize
#     cellSize = DefaultCellSize

#     graph = "tests/circuits/fixtures/proof_main.bin"
#     r1cs = "tests/circuits/fixtures/proof_main.r1cs"
#     zkey = "tests/circuits/fixtures/proof_main.zkey"

#     repoTmp = TempLevelDb.new()
#     metaTmp = TempLevelDb.new()

#   var
#     store: BlockStore
#     manifest: Manifest
#     protected: Manifest
#     verifiable: Manifest
#     nimGroth16: NimGroth16BackendRef
#     proofInputs: ProofInputs[Poseidon2Hash]
#     challenge: array[32, byte]
#     builder: Poseidon2Builder
#     sampler: Poseidon2Sampler

#   setup:
#     let
#       repoDs = repoTmp.newDb()
#       metaDs = metaTmp.newDb()

#     store = RepoStore.new(repoDs, metaDs)

#     (manifest, protected, verifiable) = await createVerifiableManifest(
#       store, numDatasetBlocks, ecK, ecM, blockSize, cellSize
#     )

#     builder = Poseidon2Builder.new(store, verifiable).tryGet
#     sampler = Poseidon2Sampler.new(slotId, store, builder).tryGet

#     nimGroth16 = NimGroth16BackendRef.new(graph, r1cs, zkey, tp = Taskpool.new()).tryGet
#     challenge = 1234567.toF.toBytes.toArray32

#     proofInputs = (await sampler.getProofInput(challenge, samples)).tryGet

#   teardown:
#     nimGroth16.release()
#     await repoTmp.destroyDb()
#     await metaTmp.destroyDb()

#   test "Should verify with correct input":
#     var proof = (await nimGroth16.prove(proofInputs)).tryGet
#     check (await nimGroth16.verify(proof)).tryGet

#   test "Should not verify with incorrect input":
#     proofInputs.slotIndex = 1 # change slot index

#     let proof = (await nimGroth16.prove(proofInputs)).tryGet
#     check (await nimGroth16.verify(proof)).tryGet == false
