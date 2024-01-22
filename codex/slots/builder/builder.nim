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
import pkg/questionable
import pkg/questionable/results
import pkg/poseidon2
import pkg/poseidon2/io
import pkg/constantine/math/arithmetic/finite_fields

import ../../indexingstrategy
import ../../merkletree
import ../../stores
import ../../manifest
import ../../utils
import ../../utils/asynciter
import ../../utils/digest
import ../../utils/poseidon2digest
import ../converters

export converters, asynciter

logScope:
  topics = "codex slotsbuilder"

const
  # TODO: Unified with the DefaultCellSize specified in branch "data-sampler"
  # in the proving circuit.

  DefaultEmptyBlock* = newSeq[byte](DefaultBlockSize.int)
  DefaultEmptyCell* = newSeq[byte](DefaultCellSize.int)

type
  # TODO: should be a generic type that
  # supports all merkle trees
  SlotsBuilder*[T, H] = ref object of RootObj
    store: BlockStore
    manifest: Manifest
    strategy: IndexingStrategy
    cellSize: NBytes
    emptyDigestTree: T
    blockPadBytes: seq[byte]
    slotsPadLeafs: seq[H]
    rootsPadLeafs: seq[H]
    slotRoots: seq[H]
    verifyTree: ?T

func slotRoots*[T, H](self: SlotsBuilder[T, H]): seq[H] =
  ## Returns the slot roots.
  ##

  self.slotRoots

func verifyTree*[T, H](self: SlotsBuilder[T, H]): ?T =
  ## Returns the slots tree (verification tree).
  ##

  self.verifyTree

func verifyRoot*[T, H](self: SlotsBuilder[T, H]): ?H =
  ## Returns the slots root (verification root).
  ##

  self.verifyTree.?root().?toOption

func nextPowerOfTwoPad*(a: int): int =
  ## Returns the difference between the original
  ## value and the next power of two.
  ##

  nextPowerOfTwo(a) - a

func numBlockPadBytes*[T, H](self: SlotsBuilder[T, H]): Natural =
  ## Number of padding bytes required for a pow2
  ## merkle tree for each block.
  ##

  self.blockPadBytes.len

func numSlotsPadLeafs*[T, H](self: SlotsBuilder[T, H]): Natural =
  ## Number of padding field elements required for a pow2
  ## merkle tree for each slot.
  ##

  self.slotsPadLeafs.len

func numRootsPadLeafs*[T, H](self: SlotsBuilder[T, H]): Natural =
  ## Number of padding field elements required for a pow2
  ## merkle tree for the slot roots.
  ##

  self.rootsPadLeafs.len

func numSlots*[T, H](self: SlotsBuilder[T, H]): Natural =
  ## Number of slots.
  ##

  self.manifest.numSlots

func numSlotBlocks*[T, H](self: SlotsBuilder[T, H]): Natural =
  ## Number of blocks per slot.
  ##

  self.manifest.blocksCount div self.manifest.numSlots

func slotBytes*[T, H](self: SlotsBuilder[T, H]): NBytes =
  ## Number of bytes per slot.
  ##

  (self.manifest.blockSize.int * self.numSlotBlocks).NBytes

func numBlockCells*[T, H](self: SlotsBuilder[T, H]): Natural =
  ## Number of cells per block.
  ##

  (self.manifest.blockSize div self.cellSize).Natural

func cellSize*[T, H](self: SlotsBuilder[T, H]): NBytes =
  ## Cell size.
  ##

  self.cellSize

func numSlotCells*[T, H](self: SlotsBuilder[T, H]): Natural =
  ## Number of cells per slot.
  ##

  self.numBlockCells * self.numSlotBlocks

func slotIndiciesIter*[T, H](self: SlotsBuilder[T, H], slot: Natural): ?!Iter[int] =
  ## Returns the slot indices.
  ##

  self.strategy.getIndicies(slot).catch

func slotIndicies*[T, H](self: SlotsBuilder[T, H], slot: Natural): seq[int] =
  ## Returns the slot indices.
  ##

  if iter =? self.strategy.getIndicies(slot).catch:
    toSeq(iter)
  else:
    trace "Failed to get slot indicies"
    newSeq[int]()

func manifest*[T, H](self: SlotsBuilder[T, H]): Manifest =
  ## Returns the manifest.
  ##

  self.manifest

proc buildBlockTree*[T, H](
  self: SlotsBuilder[T, H],
  blkIdx: Natural): Future[?!(seq[byte], T)] {.async.} =
  without blk =? await self.store.getBlock(self.manifest.treeCid, blkIdx), err:
    error "Failed to get block CID for tree at index"
    return failure(err)

  if blk.isEmpty:
    success (DefaultEmptyBlock & self.blockPadBytes, self.emptyDigestTree)
  else:
    without tree =?
      T.digestTree(blk.data & self.blockPadBytes, self.cellSize.int), err:
      error "Failed to create digest for block"
      return failure(err)

    success (blk.data, tree)

proc getCellHashes*[T, H](
  self: SlotsBuilder[T, H],
  slotIndex: Natural): Future[?!seq[H]] {.async.} =

  let
    treeCid = self.manifest.treeCid
    blockCount = self.manifest.blocksCount
    numberOfSlots = self.manifest.numSlots

  logScope:
    treeCid = treeCid
    blockCount = blockCount
    numberOfSlots = numberOfSlots
    index = blkIdx
    slotIndex = slotIndex

  let
    hashes: seq[H] = collect(newSeq):
      for blkIdx in self.strategy.getIndicies(slotIndex):
        trace "Getting block CID for tree at index"

        without (_, tree) =? (await self.buildBlockTree(blkIdx)) and
          digest =? tree.root, err:
          error "Failed to get block CID for tree at index", err = err.msg
          return failure(err)

        digest

  success hashes

proc buildSlotTree*[T, H](
  self: SlotsBuilder[T, H],
  slotIndex: Natural): Future[?!T] {.async.} =
  without cellHashes =? (await self.getCellHashes(slotIndex)), err:
    error "Failed to select slot blocks", err = err.msg
    return failure(err)

  T.init(cellHashes & self.slotsPadLeafs)

proc buildSlot*[T, H](
  self: SlotsBuilder[T, H],
  slotIndex: Natural): Future[?!H] {.async.} =
  ## Build a slot tree and store it in the block store.
  ##

  logScope:
    cid         = self.manifest.treeCid
    slotIndex   = slotIndex

  trace "Building slot tree"

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

func buildVerifyTree*[T, H](
  self: SlotsBuilder[T, H],
  slotRoots: openArray[H]): ?!T =
  T.init(@slotRoots & self.rootsPadLeafs)

proc buildSlots*[T, H](self: SlotsBuilder[T, H]): Future[?!void] {.async.} =
  ## Build all slot trees and store them in the block store.
  ##

  logScope:
    cid         = self.manifest.treeCid
    blockCount  = self.manifest.blocksCount

  trace "Building slots"

  if self.slotRoots.len == 0:
    self.slotRoots = collect(newSeq):
      for i in 0..<self.manifest.numSlots:
        without slotRoot =? (await self.buildSlot(i)), err:
          error "Failed to build slot", err = err.msg, index = i
          return failure(err)
        slotRoot

  without tree =? self.buildVerifyTree(self.slotRoots) and root =? tree.root, err:
    error "Failed to build slot roots tree", err = err.msg
    return failure(err)

  if verifyTree =? self.verifyTree and verifyRoot =? verifyTree.root:
    if verifyRoot != root: # TODO: `!=` doesn't work for SecretBool
        return failure "Existing slots root doesn't match reconstructed root."

  self.verifyTree = some tree

  success()

proc buildManifest*[T, H](self: SlotsBuilder[T, H]): Future[?!Manifest] {.async.} =
  if err =? (await self.buildSlots()).errorOption:
    error "Failed to build slot roots", err = err.msg
    return failure(err)

  without rootCids =? self.slotRoots.toSlotCids(), err:
    error "Failed to map slot roots to CIDs", err = err.msg
    return failure(err)

  without rootProvingCidRes =? self.verifyRoot.?toVerifyCid() and
    rootProvingCid =? rootProvingCidRes, err: # TODO: why doesn't `.?` unpack the result?
    error "Failed to map slot roots to CIDs", err = err.msg
    return failure(err)

  Manifest.new(self.manifest, rootProvingCid, rootCids)

proc new*[T, H](
  _: type SlotsBuilder[T, H],
  store: BlockStore,
  manifest: Manifest,
  strategy: ?IndexingStrategy = none IndexingStrategy,
  cellSize = DefaultCellSize): ?!SlotsBuilder[T, H] =

  if not manifest.protected:
    return failure("Can only create SlotsBuilder using protected manifests.")

  if (manifest.blocksCount mod manifest.numSlots) != 0:
    return failure("Number of blocks must be divisable by number of slots.")

  if (manifest.blockSize mod cellSize) != 0.NBytes:
    return failure("Block size must be divisable by cell size.")

  let
    strategy = if strategy.isNone:
      ? SteppedIndexingStrategy.new(
        0, manifest.blocksCount - 1, manifest.numSlots).catch
      else:
        strategy.get

    # all trees have to be padded to power of two
    numBlockCells = (manifest.blockSize div cellSize).int                         # number of cells per block
    blockPadBytes = newSeq[byte](numBlockCells.nextPowerOfTwoPad * cellSize.int)  # power of two padding for blocks
    numSlotLeafs = (manifest.blocksCount div manifest.numSlots)
    slotsPadLeafs = newSeqWith(numSlotLeafs.nextPowerOfTwoPad, Poseidon2Zero)     # power of two padding for block roots
    rootsPadLeafs = newSeqWith(manifest.numSlots.nextPowerOfTwoPad, Poseidon2Zero)
    emptyDigestTree = ? T.digestTree(DefaultEmptyBlock & blockPadBytes, DefaultCellSize.int)

  var self = SlotsBuilder[T, H](
    store: store,
    manifest: manifest,
    strategy: strategy,
    cellSize: cellSize,
    blockPadBytes: blockPadBytes,
    slotsPadLeafs: slotsPadLeafs,
    rootsPadLeafs: rootsPadLeafs,
    emptyDigestTree: emptyDigestTree)

  if manifest.verifiable:
    if manifest.slotRoots.len == 0 or manifest.slotRoots.len != manifest.numSlots:
      return failure "Manifest is verifiable but slot roots are missing or invalid."

    let slotRoots = manifest.slotRoots.mapIt( (? it.fromSlotCid() ))

    without tree =? self.buildVerifyTree(slotRoots), err:
      error "Failed to build slot roots tree", err = err.msg
      return failure(err)

    without expectedRoot =? manifest.verifyRoot.fromVerifyCid(), err:
      error "Unable to convert manifest verifyRoot to hash", error = err.msg
      return failure(err)

    if verifyRoot =? tree.root:
      if verifyRoot != expectedRoot:
        return failure "Existing slots root doesn't match reconstructed root."

    self.slotRoots = slotRoots
    self.verifyTree = some tree

  success self
