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
import pkg/questionable/results

import pkg/libp2p/cid

import ../../manifest
import ../../merkletree
import ../../stores
import ../../market

import ../builder
import ../sampler

import ./backends
import ../types

export backends

type
  AnyProof* = CircomProof
  AnyInputs* = CircomInputs
  AnyKeys* = CircomKey
  AnyHash* = Poseidon2Hash
  AnyBackend* = CircomCompat

  Prover* = ref object of RootObj
    backend: AnyBackend
    store: BlockStore

proc prove*(
  self: Prover,
  slotIdx: int,
  manifest: Manifest,
  challenge: ProofChallenge): Future[?!AnyProof] {.async.} =
  ## Prove a statement using backend.
  ## Returns a future that resolves to a proof.

  logScope:
    cid = manifest.treeCid
    slot = slotIdx
    challenge = challenge

  trace "Received proof challenge"

  without builder =? Poseidon2Builder.new(self.store, manifest), err:
    error "Unable to create slots builder", err = err.msg
    return failure(err)

  without sampler =? Poseidon2Sampler.new(slotIdx, self.store, builder), err:
    error "Unable to create data sampler", err = err.msg
    return failure(err)

  without proofInput =? await sampler.getProofInput(challenge, nSamples = 3), err:
    error "Unable to get proof input for slot", err = err.msg
    return failure(err)

  # prove slot
  without proof =? self.backend.prove(proofInput), err:
    error "Unable to prove slot", err = err.msg
    return failure(err)

  success proof

proc verify*(
  self: Prover,
  proof: AnyProof,
  inputs: AnyInputs,
  vpk: AnyKeys): Future[?!bool] {.async.} =
  ## Prove a statement using backend.
  ## Returns a future that resolves to a proof.

  discard self.backend.verify(proof, inputs, vpk)

proc new*(
  _: type Prover,
  store: BlockStore,
  backend: AnyBackend): Prover =

  Prover(
    backend: backend,
    store: store)
