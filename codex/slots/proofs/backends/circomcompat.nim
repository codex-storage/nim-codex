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
import ../../../codextypes
import ../../../contracts

import ./converters

export circomcompat, converters

type
  CircomCompat* = object
    slotDepth     : int     # max depth of the slot tree
    datasetDepth  : int     # max depth of dataset  tree
    blkDepth      : int     # depth of the block merkle tree (pow2 for now)
    cellElms      : int     # number of field elements per cell
    numSamples    : int     # number of samples per slot
    r1csPath      : string  # path to the r1cs file
    wasmPath      : string  # path to the wasm file
    zKeyPath      : string  # path to the zkey file
    backendCfg    : ptr CircomBn254Cfg
    vkp           : ptr CircomKey

proc release*(self: CircomCompat) =
  ## Release the backend
  ##

  self.backendCfg.unsafeAddr.releaseCfg()

proc prove*[H](
  self: CircomCompat,
  input: ProofInputs[H]): ?!CircomProof =
  ## Encode buffers using a backend
  ##

  # NOTE: All inputs are statically sized per circuit
  # and adjusted accordingly right before being passed
  # to the circom ffi - `setLen` is used to adjust the
  # sequence length to the correct size which also 0 pads
  # to the correct length
  doAssert input.samples.len == self.numSamples,
    "Number of samples does not match"

  doAssert input.slotProof.len <= self.datasetDepth,
    "Number of slot proofs does not match"

  doAssert input.samples.allIt(
    block:
      (it.merklePaths.len <= self.slotDepth + self.blkDepth and
      it.cellData.len <= self.cellElms * 32)), "Merkle paths length does not match"

  # TODO: All parameters should match circom's static parametter
  var
    backend: ptr CircomCompatCtx

  defer:
    if backend != nil:
      backend.addr.releaseCircomCompat()

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

  slotProof.setLen(self.datasetDepth) # zero pad inputs to correct size

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

    merklePaths.setLen(self.slotDepth) # zero pad inputs to correct size
    if backend.pushInputU256Array(
      "merklePaths".cstring,
      merklePaths[0].addr,
      uint (merklePaths[0].len * merklePaths.len)) != ERR_OK:
        return failure("Failed to push merkle paths")

    data.setLen(self.cellElms * 32) # zero pad inputs to correct size
    if backend.pushInputU256Array(
      "cellData".cstring,
      data[0].addr,
      data.len.uint) != ERR_OK:
        return failure("Failed to push cell data")

  var
    proofPtr: ptr Proof = nil

  let proof =
    try:
      if (
        let res = self.backendCfg.proveCircuit(backend, proofPtr.addr);
        res != ERR_OK) or
        proofPtr == nil:
        return failure("Failed to prove - err code: " & $res)

      proofPtr[]
    finally:
      if proofPtr != nil:
        proofPtr.addr.releaseProof()

  success proof

proc verify*[H](
  self: CircomCompat,
  proof: CircomProof,
  inputs: ProofInputs[H]): ?!bool =
  ## Verify a proof using a backend
  ##

  var
    proofPtr = unsafeAddr proof
    inputs = inputs.toCircomInputs()

  try:
    let res = verifyCircuit(proofPtr, inputs.addr, self.vkp)
    if res == ERR_OK:
      success true
    elif res == ERR_FAILED_TO_VERIFY_PROOF:
      success false
    else:
      failure("Failed to verify proof - err code: " & $res)
  finally:
    inputs.releaseCircomInputs()

proc init*(
  _: type CircomCompat,
  r1csPath      : string,
  wasmPath      : string,
  zKeyPath      : string = "",
  slotDepth     = DefaultMaxSlotDepth,
  datasetDepth  = DefaultMaxDatasetDepth,
  blkDepth      = DefaultBlockDepth,
  cellElms      = DefaultCellElms,
  numSamples    = DefaultSamplesNum): CircomCompat =
  ## Create a new backend
  ##

  var cfg: ptr CircomBn254Cfg
  if initCircomConfig(
    r1csPath.cstring,
    wasmPath.cstring,
    if zKeyPath.len > 0: zKeyPath.cstring else: nil,
    addr cfg) != ERR_OK or cfg == nil:
      raiseAssert("failed to initialize circom compat config")

  var
    vkpPtr: ptr VerifyingKey = nil

  if cfg.getVerifyingKey(vkpPtr.addr) != ERR_OK or vkpPtr == nil:
    raiseAssert("Failed to get verifying key")

  CircomCompat(
    r1csPath    : r1csPath,
    wasmPath    : wasmPath,
    zKeyPath    : zKeyPath,
    slotDepth   : slotDepth,
    datasetDepth: datasetDepth,
    blkDepth    : blkDepth,
    cellElms    : cellElms,
    numSamples  : numSamples,
    backendCfg  : cfg,
    vkp: vkpPtr)
