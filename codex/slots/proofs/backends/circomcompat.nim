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

export circomcompat

type
  CircomCompat*[H, P] = ref object of RootObj
    r1csPath : string
    wasmPath : string
    zKeyPath : string
    backend  : ptr CircomCompatCtx

proc release*[H, P](self: CircomCompat[H, P]) =
  ## Release the backend
  ##

  self.backend.addr.releaseCircomCompat()

proc prove*[H, P](
  self: CircomCompat[H, P],
  input: ProofInput[H]): Future[?!P] {.async.} =
  ## Encode buffers using a backend
  ##

  var
    entropy = input.entropy.toBytes
    verifyRoot = input.verifyRoot.toBytes

  if self.backend.pushInputU256Array(
    "entropy".cstring, entropy.addr, entropy.len.uint32) != ERR_OK:
    return failure("Failed to push entropy")

  if self.backend.pushInputU256Array(
    "dataSetRoot".cstring, verifyRoot.addr, verifyRoot.len.uint32) != ERR_OK:
    return failure("Failed to push data set root")

  if self.backend.pushInputU32(
    "nCellsPerSlot".cstring, input.numCells.uint32) != ERR_OK:
    return failure("Failed to push nCellsPerSlot")

  if self.backend.pushInputU32(
    "nSlotsPerDataSet".cstring, input.numSlots.uint32) != ERR_OK:
    return failure("Failed to push nSlotsPerDataSet")

  if self.backend.pushInputU32(
    "slotIndex".cstring, input.slotIndex.uint32) != ERR_OK:
    return failure("Failed to push slotIndex")

  var
    slotProof = input.verifyProof.mapIt( it.toBytes ).concat

  # arrays are always flattened
  if self.backend.pushInputU256Array(
    "slotProof".cstring,
    slotProof.addr,
    uint input.verifyProof.len) != ERR_OK:
      return failure("Failed to push slot proof")

  for s in input.samples:
    var
      merklePaths = s.merkleProof.mapIt( it.toBytes ).concat
      data = s.data

    if self.backend.pushInputU256Array(
      "merklePaths".cstring,
      merklePaths[0].addr,
      uint merklePaths.len) != ERR_OK:
        return failure("Failed to push merkle paths")

    if self.backend.pushInputU256Array(
      "cellData".cstring,
      data[0].addr,
      uint data.len) != ERR_OK:
        return failure("Failed to push cell data")

  var
    proofPtr: ptr Proof = nil

  let
    proof =
      try:
        if self.backend.proveCircuit(proofPtr.addr) != ERR_OK or
          proofPtr == nil:
          return failure("Failed to prove")

        proofPtr[]
      finally:
        if proofPtr != nil:
          release_proof(proofPtr.addr)

  success proof

proc verify*[H, P](self: CircomCompat[H, P], proof: P): Future[?!bool] {.async.} =
  ## Verify a proof using a backend
  ##

  var
    inputsPtr: ptr Inputs = nil
    vkPtr: ptr VerifyingKey = nil

  if (let res = self.backend.getVerifyingKey(vkPtr.addr); res != ERR_OK) or
    vkPtr == nil:
    return failure("Failed to get verifying key - err code: " & $res)

  if (let res = self.backend.getPubInputs(inputsPtr.addr); res != ERR_OK) or
    inputsPtr == nil:
    return failure("Failed to get public inputs - err code: " & $res)

  try:
    let res = verifyCircuit(proof.unsafeAddr, inputsPtr, vkPtr)
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

proc new*[H, P](
  _: type CircomCompat[H, P],
  r1csPath: string,
  wasmPath: string,
  zKeyPath: string = ""): CircomCompat[H, P] =
  ## Create a new backend
  ##

  var backend: ptr CircomCompatCtx
  if initCircomCompat(
    r1csPath.cstring,
    wasmPath.cstring,
    if zKeyPath.len > 0: zKeyPath.cstring else: nil,
    addr backend) != ERR_OK or backend == nil:
    raiseAssert("failed to initialize CircomCompat backend")

  CircomCompat[H, P](
    r1csPath: r1csPath,
    wasmPath: wasmPath,
    zKeyPath: zKeyPath,
    backend: backend)
