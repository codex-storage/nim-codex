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

import pkg/constantine/math/arithmetic

import pkg/constantine/math/arithmetic
import pkg/constantine/math/io/io_bigints

export circomcompat

type
  CircomCompat* = object
    r1csPath    : string
    wasmPath    : string
    zKeyPath    : string
    backendCfg  : ptr CircomBn254Cfg

  CircomG1* = G1
  CircomG2* = G2

  CircomProof* = Proof
  CircomInputs* = Inputs
  CircomKey* = VerifyingKey

proc release*(self: CircomCompat) =
  ## Release the backend
  ##

  self.backendCfg.unsafeAddr.releaseCfg()

proc getVerifyingKey*(
  self: CircomCompat): ?!ptr CircomKey =
  ## Get the verifying key
  ##

  var
    cfg: ptr CircomBn254Cfg = self.backendCfg
    vkpPtr: ptr VerifyingKey = nil

  if cfg.getVerifyingKey(vkpPtr.addr) != ERR_OK or vkpPtr == nil:
    return failure("Failed to get verifying key")

  success vkpPtr

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
        proofPtr.addr.releaseProof()

      if backend != nil:
        backend.addr.releaseCircomCompat()

  success proof

proc verify*(
  self: CircomCompat,
  proof: CircomProof,
  inputs: CircomInputs,
  vkp: CircomKey): ?!bool =
  ## Verify a proof using a backend
  ##

  var
    proofPtr : ptr Proof = unsafeAddr proof
    inputsPtr: ptr Inputs = unsafeAddr inputs
    vpkPtr: ptr CircomKey = unsafeAddr vkp

  let res = verifyCircuit(proofPtr, inputsPtr, vpkPtr)
  if res == ERR_OK:
    success true
  elif res == ERR_FAILED_TO_VERIFY_PROOF:
    success false
  else:
    failure("Failed to verify proof - err code: " & $res)

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
