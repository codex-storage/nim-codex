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
import pkg/stew/arrayops

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

  Sample*[P] = object
    data*: Cell
    slotProof*: P
    cellProof*: P
    slotBlockIdx*: Natural
    blockCellIdx*: Natural

  ProofInput*[H, P] = object
    entropy*: H
    verifyRoot*: H
    verifyProof*: P
    numSlots*: Natural
    numCells*: Natural
    slotIndex*: Natural
    samples*: seq[Sample[P]]

  DataSampler*[T, H, P] = ref object of RootObj
    index: Natural
    blockStore: BlockStore
    # The following data is invariant over time for a given slot:
    builder: SlotsBuilder[T, H]

proc getCell*[T, H, P](self: DataSampler[T, H, P], blkBytes: seq[byte], blkCellIdx: Natural): Cell =
  let
    cellSize = self.builder.cellSize.uint64
    dataStart = cellSize * blkCellIdx.uint64
    dataEnd = dataStart + cellSize
  return blkBytes[dataStart ..< dataEnd]

proc getProofInput*[T, H, P](
  self: DataSampler[T, H, P],
  entropy: ProofChallenge,
  nSamples: Natural): Future[?!ProofInput[H, P]] {.async.} =
  ## Generate proofs as input to the proving circuit.
  ##

  let
    entropy = H.fromBytes(
      array[31, byte].initCopyFrom(entropy[0..30])) # truncate to 31 bytes, otherwise it _might_ be greater than mod

  without verifyTree =? self.builder.verifyTree and
    verifyProof =? verifyTree.getProof(self.index) and
    verifyRoot =? verifyTree.root(), err:
    error "Failed to get slot proof from verify tree", err = err.msg
    return failure(err)

  let
    slotTreeCid = self.builder.manifest.slotRoots[self.index]
    cellsPerBlock = self.builder.numBlockCells
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
        blkCellIdx = cellIdx.toBlockCellIdx(cellsPerBlock) # block cell index
        slotCellIdx = cellIdx.toBlockIdx(cellsPerBlock) # slot tree index

      logScope:
        cellIdx = cellIdx
        slotCellIdx = slotCellIdx
        blkCellIdx = blkCellIdx

      without (cid, proof) =? await self.blockStore.getCidAndProof(
        slotTreeCid,
        slotCellIdx.Natural), err:
        error "Failed to get block from block store", err = err.msg
        return failure(err)

      without slotProof =? proof.toVerifiableProof(), err:
        error "Unable to convert slot proof to poseidon proof", error = err.msg
        return failure(err)

      # This converts our slotBlockIndex to a datasetBlockIndex using the
      # indexing-strategy used by the builder.
      # We need this to fetch the block data. We can't do it by slotTree + slotBlkIdx.
      let datasetBlockIndex = self.builder.slotIndicies(self.index)[slotCellIdx]

      without (bytes, blkTree) =? await self.builder.buildBlockTree(datasetBlockIndex), err:
        error "Failed to build block tree", err = err.msg
        return failure(err)

      without blockProof =? blkTree.getProof(blkCellIdx), err:
        error "Failed to get proof from block tree", err = err.msg
        return failure(err)

      Sample[P](
        data: self.getCell(bytes, blkCellIdx),
        slotProof: slotProof,
        cellProof: blockProof,
        slotBlockIdx: slotCellIdx.Natural,
        blockCellIdx: blkCellIdx.Natural)

  success ProofInput[H, P](
    entropy: entropy,
    verifyRoot: verifyRoot,
    verifyProof: verifyProof,
    numSlots: self.builder.numSlots,
    numCells: self.builder.numSlotCells,
    slotIndex: self.index,
    samples: samples)

proc new*[T, H, P](
    _: type DataSampler[T, H, P],
    index: Natural,
    blockStore: BlockStore,
    builder: SlotsBuilder[T, H]): ?!DataSampler[T, H, P] =

  if index > builder.slotRoots.high:
    error "Slot index is out of range"
    return failure("Slot index is out of range")

  success DataSampler[T, H, P](
    index: index,
    blockStore: blockStore,
    builder: builder)
