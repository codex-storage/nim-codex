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
import pkg/confutils/defs

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
  AnyBackend* = CircomCompat
  AnyProof* = CircomProof

  AnySampler* = Poseidon2Sampler
  AnyBuilder* = Poseidon2Builder

  AnyProofInputs* = ProofInputs[Poseidon2Hash]
  Prover* = ref object of RootObj
    backend: ?AnyBackend
    store: BlockStore
    nSamples: int

proc prove*(
  self: Prover,
  slotIdx: int,
  manifest: Manifest,
  challenge: ProofChallenge): Future[?!(AnyProofInputs, AnyProof)] {.async.} =
  ## Prove a statement using backend.
  ## Returns a future that resolves to a proof.

  logScope:
    cid = manifest.treeCid
    slot = slotIdx
    challenge = challenge

  trace "Received proof challenge"

  if backend =? self.backend:
    without builder =? AnyBuilder.new(self.store, manifest), err:
      error "Unable to create slots builder", err = err.msg
      return failure(err)

    without sampler =? AnySampler.new(slotIdx, self.store, builder), err:
      error "Unable to create data sampler", err = err.msg
      return failure(err)

    without proofInput =? await sampler.getProofInput(challenge, self.nSamples), err:
      error "Unable to get proof input for slot", err = err.msg
      return failure(err)

    # prove slot
    without proof =? backend.prove(proofInput), err:
      error "Unable to prove slot", err = err.msg
      return failure(err)

    success (proofInput, proof)
  else:
    return failure("Prover was not started")

proc verify*(
  self: Prover,
  proof: AnyProof,
  inputs: AnyProofInputs): Future[?!bool] {.async.} =
  ## Prove a statement using backend.
  ## Returns a future that resolves to a proof.

  if backend =? self.backend:
    return backend.verify(proof, inputs)
  else:
    return failure("Prover was not started")

proc initializeFromConfig(
  self: Prover,
  config: CodexConf): ?!void =

  # check provided files exist
  # initialize backend with files
  # or failure

  self.backend = some CircomCompat.init($config.circomR1cs, $config.circomWasm, $config.circomZkey)
  success()

proc initializeFromCeremonyFiles(
  self: Prover): ?!void =

  # initialize from previously-downloaded files if they exist
  echo "todo"
  success()

proc initializeFromCeremonyUrl(
  self: Prover,
  proofCeremonyUrl: ?string): Future[?!void] {.async.} =

  # download the ceremony url
  # unzip it
  return self.initializeFromCeremonyFiles()

proc start*(
  self: Prover,
  config: CodexConf,
  proofCeremonyUrl: ?string): Future[?!void] {.async.} =
  if cliErr =? self.initializeFromConfig(config).errorOption:
    info "Could not initialize prover backend from CLI options...", msg = cliErr.msg
    if localErr =? self.initializeFromCeremonyFiles().errorOption:
      info "Could not initialize prover backend from local files...", msg = localErr.msg
      if urlErr =? (await self.initializeFromCeremonyUrl(proofCeremonyUrl)).errorOption:
        warn "Could not initialize prover backend from ceremony url...", msg = urlErr.msg
        return failure(urlErr)
  return success()

proc new*(
  _: type Prover,
  store: BlockStore,
  nSamples: int): Prover =

  Prover(
    store: store,
    backend: none AnyBackend,
    nSamples: nSamples)
