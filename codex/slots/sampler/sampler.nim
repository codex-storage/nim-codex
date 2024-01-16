## Nim-Codex
## Copyright (c) 2023 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import std/sugar
import std/sequtils

import pkg/chronicles
import pkg/chronos
import pkg/questionable
import pkg/questionable/results
import pkg/constantine/math/arithmetic
import pkg/poseidon2
import pkg/poseidon2/types
import pkg/poseidon2/io

import ../../market
import ../../blocktype as bt
import ../../merkletree
import ../../manifest
import ../../stores

import ../builder

import ./utils

logScope:
  topics = "codex datasampler"

type
  Cell* = seq[byte]

  Sample* = object
    data*: Cell
    slotProof*: Poseidon2Proof
    cellProof*: Poseidon2Proof

  ProofInput* = object
    entropy*: Poseidon2Hash
    verifyRoot*: Poseidon2Hash
    verifyProof*: Poseidon2Proof
    numSlots*: Natural
    numCells*: Natural
    slotIndex*: Natural
    samples*: seq[Sample]

  DataSampler* = ref object of RootObj
    index: Natural
    blockStore: BlockStore
    # The following data is invariant over time for a given slot:
    builder: SlotsBuilder

proc new*(
    T: type DataSampler,
    index: Natural,
    blockStore: BlockStore,
    builder: SlotsBuilder): ?!DataSampler =

  if index > builder.slotRoots.high:
    error "Slot index is out of range"
    return failure("Slot index is out of range")

  success DataSampler(
    index: index,
    blockStore: blockStore,
    builder: builder)

proc getCell*(self: DataSampler, blkBytes: seq[byte], blkCellIdx: Natural): Cell =
  let
    cellSize = self.builder.cellSize.uint64
    dataStart = cellSize * blkCellIdx.uint64
    dataEnd = dataStart + cellSize
  return blkBytes[dataStart ..< dataEnd]

proc getProofInput*(
  self: DataSampler,
  entropy: ProofChallenge,
  nSamples: Natural): Future[?!ProofInput] {.async.} =
  ## Generate proofs as input to the proving circuit.
  ##

  without entropy =? Poseidon2Hash.fromBytes(entropy):
    error "Failed to parse entropy"
    return failure("Failed to parse entropy")

  without verifyTree =? self.builder.verifyTree and
    verifyProof =? verifyTree.getProof(self.index) and
    verifyRoot =? verifyTree.root(), err:
    error "Failed to get slot proof from verify tree", err = err.msg
    return failure(err)

  let
    slotTreeCid = self.builder.manifest.slotRoots[self.index]
    cellIdxs = entropy.cellIndices(
      self.builder.slotRoots[self.index],
      self.builder.numSlotCells,
      nSamples)

  logScope:
    index = self.index
    samples = nSamples
    cells = cellIdxs
    slotTreeCid = slotTreeCid

  trace "Collecting input for proof"
  let samples = collect(newSeq):
    for cellIdx in cellIdxs:
      let
        blockIdx = cellIdx.toBlockIdx(self.builder.numSlotCells)
        blkCellIdx = cellIdx.toBlockCellIdx(self.builder.numBlockCells)

      logScope:
        cellIdx = cellIdx
        blockIdx = blockIdx
        blkCellIdx = blkCellIdx

      without (cid, slotProof) =? await self.blockStore.getCidAndProof(
        slotTreeCid,
        blockIdx.Natural), err:
        error "Failed to get block from block store", err = err.msg
        return failure(err)

      without (bytes, blkTree) =? await self.builder.buildBlockTree(blockIdx), err:
        error "Failed to build block tree", err = err.msg
        return failure(err)

      without blockProof =? blkTree.getProof(blkCellIdx), err:
        error "Failed to get proof from block tree", err = err.msg
        return failure(err)

      let cellData = self.getCell(bytes, blkCellIdx)

      Sample(data: cellData, slotProof: slotProof, cellProof: blockProof)

  success ProofInput(
    entropy: entropy,
    verifyRoot: verifyRoot,
    verifyProof: verifyProof,
    numSlots: self.builder.numSlots,
    numCells: self.builder.numSlotCells,
    slotIndex: self.index,
    samples: samples)
