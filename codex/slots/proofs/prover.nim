## Nim-Codex
## Copyright (c) 2024 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.
##

import std/atomics

import pkg/chronos
import pkg/chronos/threadsync
import pkg/chronicles
import pkg/circomcompat
import pkg/poseidon2
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

export backends

logScope:
  topics = "codex prover"

type
  AnyProof* = CircomProof

  AnySampler* = Poseidon2Sampler
  AnyBuilder* = Poseidon2Builder

  AnyProofInputs* = ProofInputs[Poseidon2Hash]
  Prover* = ref object of RootObj
    backend: AnyBackend
    store: BlockStore
    nSamples: int

  ProveTask[H] = object
    circom: ptr CircomCompat
    proof: ptr Proof
    inputs: ptr NormalizedProofInputs[H]
    success: Atomic[bool]
    signal: ThreadSignalPtr

# proc circomProveTask*(tp: Taskpool, t: ptr ProveTask) {.gcsafe.} = # prove slot
#   defer:
#     discard t[].signal.fireSync()
#   without _ =? t[].backend[].prove(t.proofInputs[]), err:
#     error "Unable to prove slot", err = err.msg
#     t.success.store(false)
#     return

#   t.success.store(true)

proc createProofTask[H](
    backend: AnyBackend,
    proofInputs: ptr NormalizedProofInputs[H],
    proof: ProofPtr,
    signal: ThreadSignalPtr,
): ProveTask[H] =
  ProveTask[H](circom: addr backend, inputs: proofInputs, proof: proof, signal: signal)

proc circomProveTask(tp: Taskpool, t: ptr ProveTask) {.gcsafe.} =
  defer:
    discard t[].signal.fireSync()

  without _ =? t[].circom[].prove(t.inputs, t.proof), err:
    error "Unable to prove slot", err = err.msg
    t.success.store(false)
    return

  t.success.store(true)

proc asyncProve*(
    self: Prover, input: ProofInputs, proof: ptr Proof
): Future[?!void] {.async: (raises: [CancelledError]).} =
  without threadPtr =? ThreadSignalPtr.new():
    return failure("Unable to create thread signal")

  defer:
    threadPtr.close().expect("closing once works")

  var normalInputs = self.backend.normalizeInput(input)

  var

    #var task = ProveTask(circom: addr self.backend,inputs:addr normalInputs, proof: proof, signal: threadPtr)
    task = createProofTask(self.backend, addr normalInputs, proof, threadPtr)
  let taskPtr = addr task
  doAssert self.backend.taskpool.numThreads > 1,
    "Must have at least one separate thread or signal will never be fired"
  self.backend.taskpool.spawn circomProveTask(self.backend.taskpool, taskPtr)
  let threadFut = threadPtr.wait()

  try:
    await threadFut.join()
  except CatchableError as exc:
    try:
      await threadFut
    except AsyncError as asyncExc:
      return failure(asyncExc.msg)
    finally:
      if exc of CancelledError:
        raise (ref CancelledError) exc
      else:
        return failure(exc.msg)

  if not taskPtr.success.load():
    return failure("Failed to prove")

  success()

proc verify*(
    self: Prover, proof: AnyProof, inputs: AnyProofInputs
): Future[?!bool] {.async.} =
  ## Prove a statement using backend.
  ## Returns a future that resolves to a proof.
  without res =? (await self.backend.verify(proof, inputs)), err:
    error "Unable to verify proof", err = err.msg
    return failure(err)

  return success(res)

proc prove*(
    self: Prover, slotIdx: int, manifest: Manifest, challenge: ProofChallenge
): Future[?!(AnyProofInputs, AnyProof)] {.async.} =
  ## Prove a statement using backend.
  ## Returns a future that resolves to a proof.

  logScope:
    cid = manifest.treeCid
    slot = slotIdx
    challenge = challenge

  trace "Received proof challenge"

  without builder =? AnyBuilder.new(self.store, manifest), err:
    error "Unable to create slots builder", err = err.msg
    return failure(err)

  without sampler =? AnySampler.new(slotIdx, self.store, builder), err:
    error "Unable to create data sampler", err = err.msg
    return failure(err)

  without proofInput =? await sampler.getProofInput(challenge, self.nSamples), err:
    error "Unable to get proof input for slot", err = err.msg
    return failure(err)

  var taskProof = ProofPtr.new()
  defer:
    destroyProof(taskProof)

  # without _ =? await self.asyncProve(proofInput,taskProof),err:
  #   return failure(err)

  try:
    if err =? (await self.asyncProve(proofInput, taskProof)).errorOption:
      return failure(err)
  except CancelledError as exc:
    raise exc

  var proof: Proof

  copyProof(proof.addr, taskProof[])

  without success =? await self.verify(taskProof[], proofInput), err:
    echo "&&&&&&&&&&&&&&&&&", err.msg

  echo "#################", success

  success (proofInput, proof)

proc new*(
    _: type Prover, store: BlockStore, backend: AnyBackend, nSamples: int
): Prover =
  Prover(store: store, backend: backend, nSamples: nSamples)
