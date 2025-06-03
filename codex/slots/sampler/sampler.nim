## Nim-Codex
## Copyright (c) 2023 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import std/sugar

import pkg/chronos
import pkg/questionable
import pkg/questionable/results
import pkg/stew/arrayops

import ../../logutils
import ../../market
import ../../blocktype as bt
import ../../merkletree
import ../../manifest
import ../../stores

import ../converters
import ../builder
import ../types
import ./utils

logScope:
  topics = "codex slots sampler"

type DataSampler*[SomeTree, SomeHash] = ref object of RootObj
  index: Natural
  blockStore: BlockStore
  builder: SlotsBuilder[SomeTree, SomeHash]

func getCell*[SomeTree, SomeHash](
    self: DataSampler[SomeTree, SomeHash], blkBytes: seq[byte], blkCellIdx: Natural
): seq[SomeHash] =
  let
    cellSize = self.builder.cellSize.uint64
    dataStart = cellSize * blkCellIdx.uint64
    dataEnd = dataStart + cellSize

  doAssert (dataEnd - dataStart) == cellSize, "Invalid cell size"

  blkBytes[dataStart ..< dataEnd].elements(SomeHash).toSeq()

proc getSample*[SomeTree, SomeHash](
    self: DataSampler[SomeTree, SomeHash],
    cellIdx: int,
    slotTreeCid: Cid,
    slotRoot: SomeHash,
): Future[?!Sample[SomeHash]] {.async: (raises: [CancelledError]).} =
  let
    cellsPerBlock = self.builder.numBlockCells
    blkCellIdx = cellIdx.toCellInBlk(cellsPerBlock) # block cell index
    blkSlotIdx = cellIdx.toBlkInSlot(cellsPerBlock) # slot tree index
    origBlockIdx = self.builder.slotIndices(self.index)[blkSlotIdx]
      # convert to original dataset block index

  logScope:
    cellIdx = cellIdx
    blkSlotIdx = blkSlotIdx
    blkCellIdx = blkCellIdx
    origBlockIdx = origBlockIdx

  trace "Retrieving sample from block tree"
  let
    (_, proof) = (await self.blockStore.getCidAndProof(slotTreeCid, blkSlotIdx.Natural)).valueOr:
      return failure("Failed to get slot tree CID and proof")

    slotProof = proof.toVerifiableProof().valueOr:
      return failure("Failed to get verifiable proof")

    (bytes, blkTree) = (await self.builder.buildBlockTree(origBlockIdx, blkSlotIdx)).valueOr:
      return failure("Failed to build block tree")

    cellData = self.getCell(bytes, blkCellIdx)
    cellProof = blkTree.getProof(blkCellIdx).valueOr:
      return failure("Failed to get proof from block tree")

  success Sample[SomeHash](
    cellData: cellData, merklePaths: (cellProof.path & slotProof.path)
  )

proc getProofInput*[SomeTree, SomeHash](
    self: DataSampler[SomeTree, SomeHash], entropy: ProofChallenge, nSamples: Natural
): Future[?!ProofInputs[SomeHash]] {.async: (raises: [CancelledError]).} =
  ## Generate proofs as input to the proving circuit.
  ##

  let
    # truncate to 31 bytes, otherwise it _might_ be greater than mod
    entropy = SomeHash.fromBytes(array[31, byte].initCopyFrom(entropy[0 .. 30]))
    verifyTree = ?self.builder.verifyTree.toFailure
    slotProof = ?verifyTree.getProof(self.index)
    datasetRoot = ?verifyTree.root()
    slotTreeCid = self.builder.manifest.slotRoots[self.index]
    slotRoot = self.builder.slotRoots[self.index]
    cellIdxs = entropy.cellIndices(slotRoot, self.builder.numSlotCells, nSamples)

  logScope:
    cells = cellIdxs

  trace "Collecting input for proof"
  let samples = collect(newSeq):
    for cellIdx in cellIdxs:
      ?(await self.getSample(cellIdx, slotTreeCid, slotRoot))

  success ProofInputs[SomeHash](
    entropy: entropy,
    datasetRoot: datasetRoot,
    slotProof: slotProof.path,
    nSlotsPerDataSet: self.builder.numSlots,
    nCellsPerSlot: self.builder.numSlotCells,
    slotRoot: slotRoot,
    slotIndex: self.index,
    samples: samples,
  )

proc new*[SomeTree, SomeHash](
    _: type DataSampler[SomeTree, SomeHash],
    index: Natural,
    blockStore: BlockStore,
    builder: SlotsBuilder[SomeTree, SomeHash],
): ?!DataSampler[SomeTree, SomeHash] =
  if index > builder.slotRoots.high:
    error "Slot index is out of range"
    return failure("Slot index is out of range")

  if not builder.verifiable:
    return failure("Cannot instantiate DataSampler for non-verifiable builder")

  success DataSampler[SomeTree, SomeHash](
    index: index, blockStore: blockStore, builder: builder
  )
