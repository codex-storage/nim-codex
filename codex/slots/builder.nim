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
import pkg/constantine/math/arithmetic/finite_fields

import ../indexingstrategy
import ../merkletree
import ../stores
import ../manifest
import ../utils
import ../utils/digest
import ./converters
import ../utils/poseidon2digest

const
  # TODO: Unified with the CellSize specified in branch "data-sampler"
  # in the proving circuit.
  CellSize* = 2048

  DefaultEmptyBlock* = newSeq[byte](DefaultBlockSize.int)
  DefaultEmptyCell* = newSeq[byte](DefaultCellSize.int)

type
  # TODO: should be a generic type that
  # supports all merkle trees
  SlotsBuilder* = ref object of RootObj
    store: BlockStore
    manifest: Manifest
    strategy: IndexingStrategy
    cellSize: int
    blockEmptyDigest: Poseidon2Hash
    blockPadBytes: seq[byte]
    slotsPadLeafs: seq[Poseidon2Hash]
    rootsPadLeafs: seq[Poseidon2Hash]
    slotRoots: seq[Poseidon2Hash]
    verifyRoot: ?Poseidon2Hash

func slotRoots*(self: SlotsBuilder): seq[Poseidon2Hash] {.inline.} =
  ## Returns the slot roots.
  ##

  self.slotRoots

func verifyRoot*(self: SlotsBuilder): ?Poseidon2Hash {.inline.} =
  ## Returns the slots root (verification root).
  ##

  self.verifyRoot

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

  self.manifest.blockSize.int div self.cellSize

func mapToSlotCids(slotRoots: seq[Poseidon2Hash]): ?!seq[Cid] =
  success slotRoots.mapIt( ? it.toSlotCid )

proc getCellHashes*(
  self: SlotsBuilder,
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

        if blk.isEmpty:
          self.blockEmptyDigest
        else:
          without digest =? Poseidon2Tree.digest(blk.data & self.blockPadBytes, self.cellSize), err:
            error "Failed to create digest for block"
            return failure(err)

          digest

  success hashes

proc buildSlotTree*(
  self: SlotsBuilder,
  slotIndex: int): Future[?!Poseidon2Tree] {.async.} =
  without cellHashes =? (await self.getCellHashes(slotIndex)), err:
    error "Failed to select slot blocks", err = err.msg
    return failure(err)

  Poseidon2Tree.init(cellHashes & self.slotsPadLeafs)

proc buildSlot*(
  self: SlotsBuilder,
  slotIndex: int): Future[?!Poseidon2Hash] {.async.} =
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

func buildRootsTree*(
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

  without root =? self.buildRootsTree(self.slotRoots).?root(), err:
    error "Failed to build slot roots tree", err = err.msg
    return failure(err)

  if self.verifyRoot.isSome and self.verifyRoot.get != root:
      return failure "Existing slots root doesn't match reconstructed root."
  else:
    self.verifyRoot = some root

  success()

proc buildManifest*(self: SlotsBuilder): Future[?!Manifest] {.async.} =
  if err =? (await self.buildSlots()).errorOption:
    error "Failed to build slot roots", err = err.msg
    return failure(err)

  without rootCids =? self.slotRoots.toSlotCids(), err:
    error "Failed to map slot roots to CIDs", err = err.msg
    return failure(err)

  without rootProvingCidRes =? self.verifyRoot.?toSlotsRootsCid() and
    rootProvingCid =? rootProvingCidRes, err: # TODO: why doesn't `.?` unpack the result?
    error "Failed to map slot roots to CIDs", err = err.msg
    return failure(err)

  Manifest.new(self.manifest, rootProvingCid, rootCids)

proc new*(
  T: type SlotsBuilder,
  store: BlockStore,
  manifest: Manifest,
  strategy: ?IndexingStrategy = none IndexingStrategy,
  cellSize = CellSize): ?!SlotsBuilder =

  if not manifest.protected:
    return failure("Can only create SlotsBuilder using protected manifests.")

  if (manifest.blocksCount mod manifest.numSlots) != 0:
    return failure("Number of blocks must be divisable by number of slots.")

  if (manifest.blockSize.int mod cellSize) != 0:
    return failure("Block size must be divisable by cell size.")

  let
    strategy = if strategy.isNone:
      SteppedIndexingStrategy.new(
        0, manifest.blocksCount - 1, manifest.numSlots)
      else:
        strategy.get

    # all trees have to be padded to power of two
    numBlockCells = manifest.blockSize.int div cellSize                       # number of cells per block
    blockPadBytes = newSeq[byte](numBlockCells.nextPowerOfTwoPad * cellSize)  # power of two padding for blocks
    numSlotLeafs = (manifest.blocksCount div manifest.numSlots)
    slotsPadLeafs = newSeqWith(numSlotLeafs.nextPowerOfTwoPad, Poseidon2Zero) # power of two padding for block roots
    rootsPadLeafs = newSeqWith(manifest.numSlots.nextPowerOfTwoPad, Poseidon2Zero)
    blockEmptyDigest = ? Poseidon2Tree.digest(DefaultEmptyBlock & blockPadBytes, CellSize)

  var self = SlotsBuilder(
    store: store,
    manifest: manifest,
    strategy: strategy,
    cellSize: cellSize,
    blockPadBytes: blockPadBytes,
    slotsPadLeafs: slotsPadLeafs,
    rootsPadLeafs: rootsPadLeafs,
    blockEmptyDigest: blockEmptyDigest)

  if manifest.verifiable:
    if manifest.slotRoots.len == 0 or manifest.slotRoots.len != manifest.numSlots:
      return failure "Manifest is verifiable but slot roots are missing or invalid."

    let
      slotRoot = ? Poseidon2Hash.fromBytes(
        ( ? manifest.verifyRoot.mhash.mapFailure ).digestBytes.toArray32
      ).toFailure

      slotRoots = manifest.slotRoots.mapIt(
        ? Poseidon2Hash.fromBytes(
          ( ? it.mhash.mapFailure ).digestBytes.toArray32
        ).toFailure
      )

    without root =? self.buildRootsTree(slotRoots).?root(), err:
      error "Failed to build slot roots tree", err = err.msg
      return failure(err)

    if slotRoot != root:
      return failure "Existing slots root doesn't match reconstructed root."

    self.slotRoots = slotRoots
    self.verifyRoot = some slotRoot

  success self
