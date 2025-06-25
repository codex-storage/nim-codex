## Nim-Codex
## Copyright (c) 2024 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.
##

import pkg/chronos
import pkg/chronicles
import pkg/circomcompat
import pkg/poseidon2
import pkg/taskpools
import pkg/questionable/results

import pkg/libp2p/cid

import ../../manifest
import ../../merkletree
import ../../stores
import ../../market
import ../../utils/poseidon2digest
import ../../conf

import ../builder
import ../sampler

import ./backends
import ../types

import pkg/constantine/math/arithmetic
import pkg/constantine/math/io/io_bigints
import pkg/constantine/math/io/io_fields

export backends

logScope:
  topics = "codex prover"

type Prover* = ref object
  case backendKind: ProverBackendCmd
  of ProverBackendCmd.nimgroth16:
    groth16Backend*: NimGroth16BackendRef
  of ProverBackendCmd.circomcompat:
    circomCompatBackend*: CircomCompatBackendRef
  nSamples: int
  tp: Taskpool

func toJsonDecimal*(big: BigInt[254]): string =
  let s = big.toDecimal.strip(leading = true, trailing = false, chars = {'0'})
  if s.len == 0: "0" else: s

func toJson*(input: ProofInputs[Poseidon2Hash]): JsonNode =
  var input = input

  %*{
    "dataSetRoot": input.datasetRoot.toBig.toJsonDecimal,
    "entropy": input.entropy.toBig.toJsonDecimal,
    "nCellsPerSlot": input.nCellsPerSlot,
    "nSlotsPerDataSet": input.nSlotsPerDataSet,
    "slotIndex": input.slotIndex,
    "slotRoot": input.slotRoot.toDecimal,
    "slotProof": input.slotProof.mapIt(it.toBig.toJsonDecimal),
    "cellData": input.samples.mapIt(it.cellData.mapIt(it.toBig.toJsonDecimal)),
    "merklePaths": input.samples.mapIt(it.merklePaths.mapIt(it.toBig.toJsonDecimal)),
  }

proc prove*[SomeSampler](
    self: Prover,
    sampler: SomeSampler,
    manifest: Manifest,
    challenge: ProofChallenge,
    verify = false,
): Future[?!(Groth16Proof, ?bool)] {.async: (raises: [CancelledError]).} =
  ## Prove a statement using backend.
  ## Returns a future that resolves to a proof.

  logScope:
    cid = manifest.treeCid
    challenge = challenge

  trace "Received proof challenge"

  let
    proofInput = ?await sampler.getProofInput(challenge, self.nSamples)
    # prove slot

  case self.backendKind
  of ProverBackendCmd.nimgroth16:
    let
      proof = ?await self.groth16Backend.prove(proofInput)
      verified =
        if verify:
          (?await self.groth16Backend.verify(proof)).some
        else:
          bool.none
    trace "Proof generated with input", input = proofInput.toJson
    return success (proof.toGroth16Proof, verified)
  of ProverBackendCmd.circomcompat:
    let
      proof = ?await self.circomCompatBackend.prove(proofInput)
      verified =
        if verify:
          (?await self.circomCompatBackend.verify(proof, proofInput)).some
        else:
          bool.none
    return success (proof.toGroth16Proof, verified)

proc new*(
    _: type Prover, backend: CircomCompatBackendRef, nSamples: int, tp: Taskpool
): Prover =
  Prover(
    circomCompatBackend: backend,
    backendKind: ProverBackendCmd.circomcompat,
    nSamples: nSamples,
    tp: tp,
  )

proc new*(
    _: type Prover, backend: NimGroth16BackendRef, nSamples: int, tp: Taskpool
): Prover =
  Prover(
    groth16Backend: backend,
    backendKind: ProverBackendCmd.nimgroth16,
    nSamples: nSamples,
    tp: tp,
  )
