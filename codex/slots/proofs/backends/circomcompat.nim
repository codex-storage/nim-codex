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
  CircomCompatParams* = object
    slotDepth*     : int     # max depth of the slot tree
    datasetDepth*  : int     # max depth of dataset  tree
    blkDepth*      : int     # depth of the block merkle tree (pow2 for now)
    cellElms*      : int     # number of field elements per cell
    numSamples*    : int     # number of samples per slot
    r1csPath*      : string  # path to the r1cs file
    wasmPath*      : string  # path to the wasm file
    zkeyPath*      : string  # path to the zkey file

  CircomCompat* = object
    params*: CircomCompatParams
    backendCfg*: ptr CircomBn254Cfg
    vkp*: ptr CircomKey

proc release*(self: CircomCompat) =
  ## Release the ctx
  ##

  if not isNil(self.backendCfg):
    self.backendCfg.unsafeAddr.releaseCfg()

  # if not isNil(self.vkp):
  #   self.vkp.unsafeAddr.release_key()

proc prove*[H](
  self: CircomCompat,
  input: ProofInputs[H]
): ?!CircomProof =
  ## Encode buffers using a ctx
  ##

  # NOTE: All inputs are statically sized per circuit
  # and adjusted accordingly right before being passed
  # to the circom ffi - `setLen` is used to adjust the
  # sequence length to the correct size which also 0 pads
  # to the correct length
  doAssert input.samples.len == self.params.numSamples,
    "Number of samples does not match"

  doAssert input.slotProof.len <= self.params.datasetDepth,
    "Number of slot proofs does not match"

  doAssert input.samples.allIt(
    block:
      (it.merklePaths.len <= self.params.slotDepth + self.params.blkDepth and
      it.cellData.len <= self.params.cellElms * 32)), "Merkle paths length does not match"

  # TODO: All parameters should match circom's static parametter
  var
    ctx: ptr CircomCompatCtx

  defer:
    if ctx != nil:
      ctx.addr.releaseCircomCompat()

  if initCircomCompat(
    self.backendCfg,
    addr ctx) != ERR_OK or ctx == nil:
    raiseAssert("failed to initialize CircomCompat ctx")

  var
    entropy = input.entropy.toBytes
    dataSetRoot = input.datasetRoot.toBytes
    slotRoot = input.slotRoot.toBytes

  if ctx.pushInputU256Array(
    "entropy".cstring, entropy[0].addr, entropy.len.uint32) != ERR_OK:
    return failure("Failed to push entropy")

  if ctx.pushInputU256Array(
    "dataSetRoot".cstring, dataSetRoot[0].addr, dataSetRoot.len.uint32) != ERR_OK:
    return failure("Failed to push data set root")

  if ctx.pushInputU256Array(
    "slotRoot".cstring, slotRoot[0].addr, slotRoot.len.uint32) != ERR_OK:
    return failure("Failed to push data set root")

  if ctx.pushInputU32(
    "nCellsPerSlot".cstring, input.nCellsPerSlot.uint32) != ERR_OK:
    return failure("Failed to push nCellsPerSlot")

  if ctx.pushInputU32(
    "nSlotsPerDataSet".cstring, input.nSlotsPerDataSet.uint32) != ERR_OK:
    return failure("Failed to push nSlotsPerDataSet")

  if ctx.pushInputU32(
    "slotIndex".cstring, input.slotIndex.uint32) != ERR_OK:
    return failure("Failed to push slotIndex")

  var
    slotProof = input.slotProof.mapIt( it.toBytes ).concat

  slotProof.setLen(self.params.datasetDepth) # zero pad inputs to correct size

  # arrays are always flattened
  if ctx.pushInputU256Array(
    "slotProof".cstring,
    slotProof[0].addr,
    uint (slotProof[0].len * slotProof.len)) != ERR_OK:
      return failure("Failed to push slot proof")

  for s in input.samples:
    var
      merklePaths = s.merklePaths.mapIt( it.toBytes )
      data = s.cellData

    merklePaths.setLen(self.params.slotDepth) # zero pad inputs to correct size
    if ctx.pushInputU256Array(
      "merklePaths".cstring,
      merklePaths[0].addr,
      uint (merklePaths[0].len * merklePaths.len)) != ERR_OK:
        return failure("Failed to push merkle paths")

    data.setLen(self.params.cellElms * 32) # zero pad inputs to correct size
    if ctx.pushInputU256Array(
      "cellData".cstring,
      data[0].addr,
      data.len.uint) != ERR_OK:
        return failure("Failed to push cell data")


  var
    proofPtr: ptr Proof = nil

  let proof =
    try:
      if (
        let res = self.backendCfg.proveCircuit(ctx, proofPtr.addr);
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
  inputs: ProofInputs[H]
): ?!bool =
  ## Verify a proof using a ctx
  ##

  var
    proof = proof
    inputs = inputs.toCircomInputs()

  try:
    let res = verifyCircuit(proof.addr, inputs.addr, self.vkp)
    if res == ERR_OK:
      success true
    elif res == ERR_FAILED_TO_VERIFY_PROOF:
      success false
    else:
      failure("Failed to verify proof - err code: " & $res)
  finally:
    inputs.releaseCircomInputs()

proc init*(
  _: type CircomCompatParams,
  r1csPath      : string,
  wasmPath      : string,
  zkeyPath      : string = "",
  slotDepth     = DefaultMaxSlotDepth,
  datasetDepth  = DefaultMaxDatasetDepth,
  blkDepth      = DefaultBlockDepth,
  cellElms      = DefaultCellElms,
  numSamples    = DefaultSamplesNum
): CircomCompatParams =
  CircomCompatParams(
    r1csPath    : r1csPath,
    wasmPath    : wasmPath,
    zkeyPath    : zkeyPath,
    slotDepth   : slotDepth,
    datasetDepth: datasetDepth,
    blkDepth    : blkDepth,
    cellElms    : cellElms,
    numSamples  : numSamples)

proc init*(
  _: type CircomCompat,
  params: CircomCompatParams
): CircomCompat =
  ## Create a new ctx
  ##

  var cfg: ptr CircomBn254Cfg
  var zkey = if params.zkeyPath.len > 0: params.zkeyPath.cstring else: nil

  if initCircomConfig(
    params.r1csPath.cstring,
    params.wasmPath.cstring,
    zkey, cfg.addr) != ERR_OK or cfg == nil:
      if cfg != nil: cfg.addr.releaseCfg()
      raiseAssert("failed to initialize circom compat config")

  var
    vkpPtr: ptr VerifyingKey = nil

  if cfg.getVerifyingKey(vkpPtr.addr) != ERR_OK or vkpPtr == nil:
    if vkpPtr != nil: vkpPtr.addr.releaseKey()
    raiseAssert("Failed to get verifying key")

  CircomCompat(params: params, backendCfg: cfg, vkp: vkpPtr)
