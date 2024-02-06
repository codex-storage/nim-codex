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
import pkg/poseidon2/io

import ../../types
import ../../../stores
import ../../../merkletree

import pkg/constantine/math/arithmetic

import pkg/constantine/math/arithmetic
import pkg/constantine/math/io/io_bigints

export circomcompat

const
  # TODO: this defaults need to be adjusted and/or replased with cli config params
  DefaultMaxDepth*       = 32
  DefaultMaxLog2NSlots*  = 8
  DefaultBlockTreeDepth* = 5
  DefaultNCellFldElms*   = 67
  DefaultNSamples*       = 5

type
  CircomCompat* = object
    r1csPath    : string
    wasmPath    : string
    zKeyPath    : string
    backendCfg  : ptr CircomBn254Cfg
    maxDepth    : int
    log2NSlots  : int
    blkDepth    : int
    cellFldElms : int
    nSamples    : int

  CircomG1* = G1
  CircomG2* = G2

  CircomProof*  = Proof
  CircomKey*    = VerifyingKey
  CircomInputs* = Inputs

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

proc prove*[H](
  self: CircomCompat,
  input: ProofInput[H]): ?!CircomProof =
  ## Encode buffers using a backend
  ##

  # TODO: All parameters should match circom's static parametter
  var
    backend: ptr CircomCompatCtx

  if initCircomCompat(
    self.backendCfg,
    addr backend) != ERR_OK or backend == nil:
    raiseAssert("failed to initialize CircomCompat backend")

  var
    entropy = input.entropy.toBytes
    dataSetRoot = input.datasetRoot.toBytes
    slotRoot = input.slotRoot.toBytes

  if backend.pushInputU256Array(
    "entropy".cstring, entropy[0].addr, entropy.len.uint32) != ERR_OK:
    return failure("Failed to push entropy")

  if backend.pushInputU256Array(
    "dataSetRoot".cstring, dataSetRoot[0].addr, dataSetRoot.len.uint32) != ERR_OK:
    return failure("Failed to push data set root")

  if backend.pushInputU256Array(
    "slotRoot".cstring, slotRoot[0].addr, slotRoot.len.uint32) != ERR_OK:
    return failure("Failed to push data set root")

  if backend.pushInputU32(
    "nCellsPerSlot".cstring, input.nCellsPerSlot.uint32) != ERR_OK:
    return failure("Failed to push nCellsPerSlot")

  if backend.pushInputU32(
    "nSlotsPerDataSet".cstring, input.nSlotsPerDataSet.uint32) != ERR_OK:
    return failure("Failed to push nSlotsPerDataSet")

  if backend.pushInputU32(
    "slotIndex".cstring, input.slotIndex.uint32) != ERR_OK:
    return failure("Failed to push slotIndex")

  var
    slotProof = input.slotProof.mapIt( it.toBytes ).concat

  slotProof.setLen(self.log2NSlots) # adjust to match circom static params

  # arrays are always flattened
  if backend.pushInputU256Array(
    "slotProof".cstring,
    slotProof[0].addr,
    uint (slotProof[0].len * slotProof.len)) != ERR_OK:
      return failure("Failed to push slot proof")

  for s in input.samples:
    var
      merklePaths = s.merklePaths.mapIt( it.toBytes )
      data = s.cellData

    merklePaths.setLen(self.maxDepth)
    if backend.pushInputU256Array(
      "merklePaths".cstring,
      merklePaths[0].addr,
      uint (merklePaths[0].len * merklePaths.len)) != ERR_OK:
        return failure("Failed to push merkle paths")

    data.setLen(self.cellFldElms * 32) # TODO: sizeof field bits/bytes
    if backend.pushInputU256Array(
      "cellData".cstring,
      data[0].addr,
      data.len.uint) != ERR_OK:
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
  r1csPath:   string,
  wasmPath:   string,
  zKeyPath:   string = "",
  maxDepth    = DefaultMaxDepth,
  log2NSlots  = DefaultMaxLog2NSlots,
  blkDepth    = DefaultBlockTreeDepth,
  cellFldElms = DefaultNCellFldElms,
  nSamples    = DefaultNSamples): CircomCompat =
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
    r1csPath:     r1csPath,
    wasmPath:     wasmPath,
    zKeyPath:     zKeyPath,
    backendCfg:   cfg,
    maxDepth:     maxDepth,
    log2NSlots:   log2NSlots,
    blkDepth:     blkDepth,
    cellFldElms:  cellFldElms,
    nSamples:     nSamples)
