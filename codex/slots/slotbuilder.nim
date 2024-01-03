## Nim-Codex
## Copyright (c) 2023 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

{.push raises: [].}

import std/math
import std/sequtils
import std/sugar

import pkg/libp2p
import pkg/chronos
import pkg/chronicles
import pkg/questionable/results
import pkg/poseidon2
import pkg/poseidon2/io

import ../indexingstrategy
import ../merkletree
import ../stores
import ../manifest
import ../utils
import ../utils/digest
import ./converters

const
  # TODO: Unified with the CellSize specified in branch "data-sampler"
  # Number of bytes in a cell. A cell is the smallest unit of data used
  # in the proving circuit.
  CellSize* = 2048

type
  SlotBuilder* = object of RootObj
    store: BlockStore
    manifest: Manifest
    strategy: IndexingStrategy
    cellSize: int
    blockPadBytes: seq[byte]
    slotsPadLeafs: seq[Poseidon2Hash]
    rootsPadLeafs: seq[Poseidon2Hash]

func numBlockPadBytes*(self: SlotBuilder): Natural =
  ## Number of padding bytes required for a pow2
  ## merkle tree for each block.
  ##

  self.blockPadBytes.len

func numSlotsPadLeafs*(self: SlotBuilder): Natural =
  ## Number of padding field elements required for a pow2
  ## merkle tree for each slot.
  ##

  self.slotsPadLeafs.len

func numRootsPadLeafs*(self: SlotBuilder): Natural =
  ## Number of padding field elements required for a pow2
  ## merkle tree for the slot roots.
  ##

  self.rootsPadLeafs.len

func numSlotBlocks*(self: SlotBuilder): Natural =
  ## Number of blocks per slot.
  ##

  self.manifest.blocksCount div self.manifest.numSlots

func numBlockRoots*(self: SlotBuilder): Natural =
  ## Number of cells per block.
  ##

  self.manifest.blockSize.int div self.cellSize

func mapToSlotCids(slotRoots: seq[Poseidon2Hash]): ?!seq[Cid] =
  success slotRoots.mapIt( ? it.toSlotCid )

proc getCellHashes*(
  self: SlotBuilder,
  slotIndex: int): Future[?!seq[Poseidon2Hash]] {.async.} =

  let
    treeCid = self.manifest.treeCid
    blockCount = self.manifest.blocksCount
    numberOfSlots = self.manifest.numSlots

  logScope:
    treeCid = treeCid
    blockCount = blockCount
    numberOfSlots = numberOfSlots
    index = blockIndex
    slotIndex = slotIndex

  let
    hashes: seq[Poseidon2Hash] = collect(newSeq):
      for blockIndex in self.strategy.getIndicies(slotIndex):
        trace "Getting block CID for tree at index"

        without blk =? (await self.store.getBlock(treeCid, blockIndex)), err:
          error "Failed to get block CID for tree at index"
          return failure(err)

        without digest =? Poseidon2Tree.digest(blk.data & self.blockPadBytes, self.cellSize), err:
          error "Failed to create digest for block"
          return failure(err)

        # TODO: Remove this sleep. It's here to prevent us from locking up the thread.
        # await sleepAsync(10.millis)

        digest

  success hashes

proc buildSlotTree*(
  self: SlotBuilder,
  slotIndex: int): Future[?!Poseidon2Tree] {.async.} =
  without cellHashes =? (await self.getCellHashes(slotIndex)), err:
    error "Failed to select slot blocks", err = err.msg
    return failure(err)

  Poseidon2Tree.init(cellHashes & self.slotsPadLeafs)

proc buildSlot*(
  self: SlotBuilder,
  slotIndex: int): Future[?!Poseidon2Hash] {.async.} =
  ## Build a slot tree and store it in the block store.
  ##

  without tree =? (await self.buildSlotTree(slotIndex)) and
    treeCid =? tree.root.?toSlotCid, err:
    error "Failed to build slot tree", err = err.msg
    return failure(err)

  trace "Storing slot tree", treeCid, slotIndex, leaves = tree.leavesCount
  for i, leaf in tree.leaves:
    without cellCid =? leaf.toCellCid, err:
      error "Failed to get CID for slot cell", err = err.msg
      return failure(err)

    without proof =? tree.getProof(i) and
      encodableProof =? proof.toEncodableProof, err:
      error "Failed to get proof for slot tree", err = err.msg
      return failure(err)

    if err =? (await self.store.putCidAndProof(
      treeCid, i, cellCid, encodableProof)).errorOption:
      error "Failed to store slot tree", err = err.msg
      return failure(err)

  tree.root()

proc buildSlots(self: SlotBuilder): Future[?!Manifest] {.async.} =
  let
    slotRoots: seq[Poseidon2Hash] = collect(newSeq):
      for i in 0..<self.manifest.numSlots:
        without root =? (await self.buildSlot(i)), err:
          error "Failed to build slot", err = err.msg, index = i
          return failure(err)
        root

  without provingRootCid =? Poseidon2Tree.init(slotRoots & self.rootsPadLeafs).?root.?toProvingCid, err:
    error "Failed to build proving tree", err = err.msg
    return failure(err)

  without rootCids =? slotRoots.mapToSlotCids(), err:
    error "Failed to map slot roots to CIDs", err = err.msg
    return failure(err)

  Manifest.new(self.manifest, provingRootCid, rootCids)

func nextPowerOfTwoPad*(a: int): int =
  ## Returns the next power of two of `a` and `b` and the difference between
  ## the original value and the next power of two.
  ##

  nextPowerOfTwo(a) - a

proc new*(
  T: type SlotBuilder,
  store: BlockStore,
  manifest: Manifest,
  strategy: IndexingStrategy = nil,
  cellSize = CellSize): ?!SlotBuilder =

  if not manifest.protected:
    return failure("Can only create SlotBuilder using protected manifests.")

  if (manifest.blocksCount mod manifest.numSlots) != 0:
    return failure("Number of blocks must be divisable by number of slots.")

  if (manifest.blockSize.int mod cellSize) != 0:
    return failure("Block size must be divisable by cell size.")

  let
    strategy = if strategy == nil:
      SteppedIndexingStrategy.new(
        0, manifest.blocksCount - 1, manifest.numSlots)
      else:
        strategy

    # all trees have to be padded to power of two
    numBlockCells = manifest.blockSize.int div cellSize                       # number of cells per block
    blockPadBytes
      = newSeq[byte](numBlockCells.nextPowerOfTwoPad * cellSize)              # power of two padding for blocks
    slotsPadLeafs
      = newSeqWith((manifest.blocksCount div manifest.numSlots).nextPowerOfTwoPad, Poseidon2Zero)                                                  # power of two padding for block roots
    rootsPadLeafs
      = newSeqWith(manifest.numSlots.nextPowerOfTwoPad, Poseidon2Zero)

  success SlotBuilder(
    store: store,
    manifest: manifest,
    strategy: strategy,
    cellSize: cellSize,
    blockPadBytes: blockPadBytes,
    slotsPadLeafs: slotsPadLeafs,
    rootsPadLeafs: rootsPadLeafs)
