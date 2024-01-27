## Nim-Codex
## Copyright (c) 2024 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

{.push raises: [].}

import std/sequtils

import pkg/chronos
import pkg/questionable/results
import pkg/circomcompat

import ../../../stores
import ../../types
import ../../../merkletree

export circomcompat

type
  CircomCompat* = object
    r1csPath    : string
    wasmPath    : string
    zKeyPath    : string
    backendCfg  : ptr CircomBn254Cfg

  CircomProof* = object
    proof*: Proof
    backend: ptr CircomCompatCtx
    cfg: ptr CircomBn254Cfg

proc release*(self: CircomCompat) =
  ## Release the backend
  ##

  self.backendCfg.unsafeAddr.releaseCfg()

proc release*(proof: CircomProof) =
  ## Release the backend context
  ##

  proof.backend.unsafeAddr.release_circom_compat()
  doAssert(proof.backend == nil)

proc prove*(
  self: CircomCompat,
  input: ProofInput[Poseidon2Hash]): ?!CircomProof =
  ## Encode buffers using a backend
  ##

  var
    backend: ptr CircomCompatCtx

  if initCircomCompat(
    self.backendCfg,
    addr backend) != ERR_OK or backend == nil:
    raiseAssert("failed to initialize CircomCompat backend")

  var
    entropy = input.entropy.toBytes
    verifyRoot = input.verifyRoot.toBytes
    slotRoot = input.slotRoot.toBytes

  if backend.pushInputU256Array(
    "entropy".cstring, entropy.addr, entropy.len.uint32) != ERR_OK:
    return failure("Failed to push entropy")

  if backend.pushInputU256Array(
    "dataSetRoot".cstring, verifyRoot.addr, verifyRoot.len.uint32) != ERR_OK:
    return failure("Failed to push data set root")

  if backend.pushInputU256Array(
    "slotRoot".cstring, slotRoot.addr, slotRoot.len.uint32) != ERR_OK:
    return failure("Failed to push data set root")

  if backend.pushInputU32(
    "nCellsPerSlot".cstring, input.numCells.uint32) != ERR_OK:
    return failure("Failed to push nCellsPerSlot")

  if backend.pushInputU32(
    "nSlotsPerDataSet".cstring, input.numSlots.uint32) != ERR_OK:
    return failure("Failed to push nSlotsPerDataSet")

  if backend.pushInputU32(
    "slotIndex".cstring, input.slotIndex.uint32) != ERR_OK:
    return failure("Failed to push slotIndex")

  var
    slotProof = input.verifyProof.mapIt( it.toBytes ).concat

  # arrays are always flattened
  if backend.pushInputU256Array(
    "slotProof".cstring,
    slotProof[0].addr,
    uint (32 * input.verifyProof.len)) != ERR_OK:
      return failure("Failed to push slot proof")

  for s in input.samples:
    var
      merklePaths = s.merkleProof.mapIt( it.toBytes )
      data = s.data

    if backend.pushInputU256Array(
      "merklePaths".cstring,
      merklePaths[0].addr,
      uint (32 * merklePaths.len)) != ERR_OK:
        return failure("Failed to push merkle paths")

    if backend.pushInputU256Array(
      "cellData".cstring,
      data[0].addr,
      uint data.len) != ERR_OK:
        return failure("Failed to push cell data")

  var
    proofPtr: ptr Proof = nil

  let proof =
    try:
      if self.backendCfg.proveCircuit(backend, proofPtr.addr) != ERR_OK or
        proofPtr == nil:
        return failure("Failed to prove")

      proofPtr[]
    finally:
      if proofPtr != nil:
        release_proof(proofPtr.addr)

  success CircomProof(
    proof: proof,
    cfg: self.backendCfg,
    backend: backend)

proc verify*(proof: CircomProof): ?!bool =
  ## Verify a proof using a backend
  ##

  var
    inputsPtr: ptr Inputs = nil
    vkPtr: ptr VerifyingKey = nil

  if (let res = proof.cfg.getVerifyingKey(vkPtr.addr); res != ERR_OK) or
    vkPtr == nil:
    return failure("Failed to get verifying key - err code: " & $res)

  if (let res = proof.backend.getPubInputs(inputsPtr.addr); res != ERR_OK) or
    inputsPtr == nil:
    return failure("Failed to get public inputs - err code: " & $res)

  try:
    let res = verifyCircuit(proof.proof.unsafeAddr, inputsPtr, vkPtr)
    if res == ERR_OK:
      success true
    elif res == ERR_FAILED_TO_VERIFY_PROOF:
      success false
    else:
      failure("Failed to verify proof - err code: " & $res)

  finally:
    if inputsPtr != nil:
      releaseInputs(inputsPtr.addr)

    if vkPtr != nil:
      releaseKey(vkPtr.addr)

proc init*(
  _: type CircomCompat,
  r1csPath: string,
  wasmPath: string,
  zKeyPath: string = ""): CircomCompat =
  ## Create a new backend
  ##

  var cfg: ptr CircomBn254Cfg
  if initCircomConfig(
    r1csPath.cstring,
    wasmPath.cstring,
    if zKeyPath.len > 0: zKeyPath.cstring else: nil,
    addr cfg) != ERR_OK or cfg == nil:
    raiseAssert("failed to initialize circom compat config")

  CircomCompat(
    r1csPath: r1csPath,
    wasmPath: wasmPath,
    zKeyPath: zKeyPath,
    backendCfg: cfg)
