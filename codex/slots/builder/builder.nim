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

export converters

const
  # TODO: Unified with the DefaultCellSize specified in branch "data-sampler"
  # in the proving circuit.

  DefaultEmptyBlock* = newSeq[byte](DefaultBlockSize.int)
  DefaultEmptyCell* = newSeq[byte](DefaultCellSize.int)

type
  # TODO: should be a generic type that
  # supports all merkle trees
  SlotsBuilder* = ref object of RootObj
    store: BlockStore
    manifest: Manifest
    strategy: IndexingStrategy
    cellSize: NBytes
    emptyDigestTree: Poseidon2Tree
    blockPadBytes: seq[byte]
    slotsPadLeafs: seq[Poseidon2Hash]
    rootsPadLeafs: seq[Poseidon2Hash]
    slotRoots: seq[Poseidon2Hash]
    verifyTree: ?Poseidon2Tree

func slotRoots*(self: SlotsBuilder): seq[Poseidon2Hash] {.inline.} =
  ## Returns the slot roots.
  ##

  self.slotRoots

func verifyTree*(self: SlotsBuilder): ?Poseidon2Tree {.inline.} =
  ## Returns the slots tree (verification tree).
  ##

  self.verifyTree

func verifyRoot*(self: SlotsBuilder): ?Poseidon2Hash {.inline.} =
  ## Returns the slots root (verification root).
  ##

  self.verifyTree.?root().?toOption

func nextPowerOfTwoPad*(a: int): int =
  ## Returns the difference between the original
  ## value and the next power of two.
  ##

  nextPowerOfTwo(a) - a

func numBlockPadBytes*(self: SlotsBuilder): Natural =
  ## Number of padding bytes required for a pow2
  ## merkle tree for each block.
  ##

  self.blockPadBytes.len

func numSlotsPadLeafs*(self: SlotsBuilder): Natural =
  ## Number of padding field elements required for a pow2
  ## merkle tree for each slot.
  ##

  self.slotsPadLeafs.len

func numRootsPadLeafs*(self: SlotsBuilder): Natural =
  ## Number of padding field elements required for a pow2
  ## merkle tree for the slot roots.
  ##

  self.rootsPadLeafs.len

func numSlots*(self: SlotsBuilder): Natural =
  ## Number of slots.
  ##

  self.manifest.numSlots

func numSlotBlocks*(self: SlotsBuilder): Natural =
  ## Number of blocks per slot.
  ##

  self.manifest.blocksCount div self.manifest.numSlots

func slotBytes*(self: SlotsBuilder): NBytes =
  ## Number of bytes per slot.
  ##

  (self.manifest.blockSize.int * self.numSlotBlocks).NBytes

func numBlockCells*(self: SlotsBuilder): Natural =
  ## Number of cells per block.
  ##

  (self.manifest.blockSize div self.cellSize).Natural

func cellSize*(self: SlotsBuilder): NBytes =
  ## Cell size.
  ##

  self.cellSize

func numSlotCells*(self: SlotsBuilder): Natural =
  ## Number of cells per slot.
  ##

  self.numBlockCells * self.numSlotBlocks

func slotIndiciesIter*(self: SlotsBuilder, slot: Natural): ?!Iter[int] =
  ## Returns the slot indices.
  ##

  self.strategy.getIndicies(slot).catch

func slotIndicies*(self: SlotsBuilder, slot: Natural): seq[int] =
  ## Returns the slot indices.
  ##

  if iter =? self.strategy.getIndicies(slot).catch:
    toSeq(iter)
  else:
    trace "Failed to get slot indicies"
    newSeq[int]()

func manifest*(self: SlotsBuilder): Manifest =
  ## Returns the manifest.
  ##

  self.manifest

proc buildBlockTree*(
  self: SlotsBuilder,
  blkIdx: Natural): Future[?!(seq[byte], Poseidon2Tree)] {.async.} =
  without blk =? await self.store.getBlock(self.manifest.treeCid, blkIdx), err:
    error "Failed to get block CID for tree at index"
    return failure(err)

  if blk.isEmpty:
    success (DefaultEmptyBlock & self.blockPadBytes, self.emptyDigestTree)
  else:
    without tree =?
      Poseidon2Tree.digestTree(blk.data & self.blockPadBytes, self.cellSize.int), err:
      error "Failed to create digest for block"
      return failure(err)

    success (blk.data, tree)

proc getCellHashes*(
  self: SlotsBuilder,
  slotIndex: Natural): Future[?!seq[Poseidon2Hash]] {.async.} =

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
    hashes: seq[Poseidon2Hash] = collect(newSeq):
      for blkIdx in self.strategy.getIndicies(slotIndex):
        trace "Getting block CID for tree at index"

        without (_, tree) =? (await self.buildBlockTree(blkIdx)) and
          digest =? tree.root, err:
          error "Failed to get block CID for tree at index", err = err.msg
          return failure(err)

        digest

  success hashes

proc buildSlotTree*(
  self: SlotsBuilder,
  slotIndex: Natural): Future[?!Poseidon2Tree] {.async.} =
  without cellHashes =? (await self.getCellHashes(slotIndex)), err:
    error "Failed to select slot blocks", err = err.msg
    return failure(err)

  Poseidon2Tree.init(cellHashes & self.slotsPadLeafs)

proc buildSlot*(
  self: SlotsBuilder,
  slotIndex: Natural): Future[?!Poseidon2Hash] {.async.} =
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

func buildVerifyTree*(
  self: SlotsBuilder,
  slotRoots: openArray[Poseidon2Hash]): ?!Poseidon2Tree =
  Poseidon2Tree.init(@slotRoots & self.rootsPadLeafs)

proc buildSlots*(self: SlotsBuilder): Future[?!void] {.async.} =
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

proc buildManifest*(self: SlotsBuilder): Future[?!Manifest] {.async.} =
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

proc new*(
  T: type SlotsBuilder,
  store: BlockStore,
  manifest: Manifest,
  strategy: ?IndexingStrategy = none IndexingStrategy,
  cellSize = DefaultCellSize): ?!SlotsBuilder =

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
    emptyDigestTree = ? Poseidon2Tree.digestTree(DefaultEmptyBlock & blockPadBytes, DefaultCellSize.int)

  var self = SlotsBuilder(
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

    let slotRoots = manifest.slotRoots.mapIt( (? it.fromSlotCid()))

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
