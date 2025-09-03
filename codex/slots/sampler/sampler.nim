## Nim-Codex
## Copyright (c) 2023 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import std/[sugar, math]

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
  topics = "codex datasampler"

type DataSampler*[T, H] = ref object of RootObj
  index: Natural
  blockStore: BlockStore
  builder: SlotsBuilder[T, H]

func getCell*[T, H](
    self: DataSampler[T, H], blkBytes: seq[byte], blkCellIdx: Natural
): seq[H] =
  let
    cellSize = self.builder.cellSize.uint64
    dataStart = cellSize * blkCellIdx.uint64
    dataEnd = dataStart + cellSize

  doAssert (dataEnd - dataStart) == cellSize, "Invalid cell size"

  blkBytes[dataStart ..< dataEnd].elements(H).toSeq()

proc getSample*[T, H](
    self: DataSampler[T, H], cellIdx: int, slotTreeCid: Cid, slotRoot: H
): Future[?!Sample[H]] {.async: (raises: [CancelledError]).} =
  let
    cellsPerBlock = self.builder.numBlockCells
    blkCellIdx = cellIdx.toCellInBlk(cellsPerBlock) # block cell index
    blkSlotIdx = cellIdx.toBlkInSlot(cellsPerBlock) # slot tree index

  logScope:
    cellIdx = cellIdx
    blkSlotIdx = blkSlotIdx
    blkCellIdx = blkCellIdx

  trace "Retrieving sample from block tree"
  let
    (_, proof) = (await self.blockStore.getCidAndProof(slotTreeCid, blkSlotIdx.Natural)).valueOr:
      return failure("Failed to get slot tree CID and proof")

    slotProof = proof.toVerifiableProof().valueOr:
      return failure("Failed to get verifiable proof")

    slotEncodedTreeCid = self.builder.manifest.slotEncodedTreeCids[self.index]

    (bytes, blkTree) = (
      await self.builder.buildBlockTree(slotEncodedTreeCid, blkSlotIdx)
    ).valueOr:
      return failure("Failed to build block tree")

    cellData = self.getCell(bytes, blkCellIdx)
    cellProof = blkTree.getProof(blkCellIdx).valueOr:
      return failure("Failed to get proof from block tree")

  success Sample[H](cellData: cellData, merklePaths: (cellProof.path & slotProof.path))

proc getProofInput*[T, H](
    self: DataSampler[T, H], entropy: ProofChallenge, nSamples: Natural
): Future[?!ProofInputs[H]] {.async: (raises: [CancelledError]).} =
  ## Generate proofs as input to the proving circuit.
  ##

  let
    entropy = H.fromBytes(array[31, byte].initCopyFrom(entropy[0 .. 30]))
      # truncate to 31 bytes, otherwise it _might_ be greater than mod

    verifyTree = self.builder.verifyTree.toFailure.valueOr:
      return failure("Failed to get verify tree")

    slotProof = verifyTree.getProof(self.index).valueOr:
      return failure("Failed to get slot proof")

    datasetRoot = verifyTree.root().valueOr:
      return failure("Failed to get dataset root")

    slotTreeCid = self.builder.manifest.slotRoots[self.index]
    slotRoot = self.builder.slotRoots[self.index]
    numSlotCellsEncoded = self.builder.numSlotCellsEncoded
    nCellsPerSlotEncoded = nextPowerOfTwo(numSlotCellsEncoded)
    cellIdxs = entropy.cellIndices(slotRoot, nCellsPerSlotEncoded, nSamples)

  logScope:
    cells = cellIdxs

  trace "Collecting input for proof"
  let sampleFutures = cellIdxs.mapIt(self.getSample(it, slotTreeCid, slotRoot))

  var samples: seq[Sample[H]] = @[]
  for i in 0 ..< sampleFutures.len:
    let res = await sampleFutures[i]
    if res.isErr:
      return
        failure("Failed to get sample for cell " & $cellIdxs[i] & ": " & res.error.msg)
    samples.add(res.get())

  success ProofInputs[H](
    entropy: entropy,
    datasetRoot: datasetRoot,
    slotProof: slotProof.path,
    nSlotsPerDataSet: self.builder.numSlots,
    nCellsPerSlot: nCellsPerSlotEncoded,
    slotRoot: slotRoot,
    slotIndex: self.index,
    samples: samples,
  )

proc new*[T, H](
    _: type DataSampler[T, H],
    index: Natural,
    blockStore: BlockStore,
    builder: SlotsBuilder[T, H],
): ?!DataSampler[T, H] =
  if index > builder.slotRoots.high:
    error "Slot index is out of range"
    return failure("Slot index is out of range")

  if not builder.verifiable:
    return failure("Cannot instantiate DataSampler for non-verifiable builder")

  success DataSampler[T, H](index: index, blockStore: blockStore, builder: builder)
