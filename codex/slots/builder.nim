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
import ../utils/poseidon2digest

const
  # TODO: Unified with the CellSize specified in branch "data-sampler"
  # in the proving circuit.
  CellSize* = 2048

type
  # TODO: should be a generic type that
  # supports all merkle trees
  SlotBuilder* = ref object of RootObj
    store: BlockStore
    manifest: Manifest
    strategy: IndexingStrategy
    cellSize: int
    blockPadBytes: seq[byte]
    slotsPadLeafs: seq[Poseidon2Hash]
    rootsPadLeafs: seq[Poseidon2Hash]
    slotRoots*: seq[Poseidon2Hash]
    slotsRoot*: ?Poseidon2Hash

func nextPowerOfTwoPad*(a: int): int =
  ## Returns the difference between the original
  ## value and the next power of two.
  ##

  nextPowerOfTwo(a) - a

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

func toCellCid*(cell: Poseidon2Hash): ?!Cid =
  let
    cellMhash = ? MultiHash.init(Pos2Bn128MrklCodec, cell.toBytes).mapFailure
    cellCid = ? Cid.init(CIDv1, CodexSlotCellCodec, cellMhash).mapFailure

  success cellCid

func toSlotCid*(root: Poseidon2Hash): ?!Cid =
  let
    mhash = ? MultiHash.init($multiCodec("identity"), root.toBytes).mapFailure
    treeCid = ? Cid.init(CIDv1, SlotRootCodec, mhash).mapFailure

  success treeCid

func toSlotsRootsCid*(root: Poseidon2Hash): ?!Cid =
  let
    mhash = ? MultiHash.init($multiCodec("identity"), root.toBytes).mapFailure
    treeCid = ? Cid.init(CIDv1, SlotProvingRootCodec, mhash).mapFailure

  success treeCid

func toSlotCids*(slotRoots: openArray[Poseidon2Hash]): ?!seq[Cid] =
  success slotRoots.mapIt( ? it.toSlotCid )

func toEncodableProof*(
  proof: Poseidon2Proof): ?!CodexProof =

  let
    encodableProof = CodexProof(
      mcodec: multiCodec("identity"), # copy bytes as is
      index: proof.index,
      nleaves: proof.nleaves,
      path: proof.path.mapIt( @(it.toBytes) ))

  success encodableProof

func toVerifiableProof*(
  proof: CodexProof): ?!Poseidon2Proof =

  let
    verifiableProof = Poseidon2Proof(
      index: proof.index,
      nleaves: proof.nleaves,
      path: proof.path.mapIt(
        ? Poseidon2Hash.fromBytes(it.toArray32).toFailure
      ))

  success verifiableProof

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

func buildRootsTree*(
  self: SlotBuilder,
  slotRoots: openArray[Poseidon2Hash]): ?!Poseidon2Tree =
  Poseidon2Tree.init(@slotRoots & self.rootsPadLeafs)

proc buildSlots*(self: SlotBuilder): Future[?!void] {.async.} =
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

  if self.slotsRoot.isSome and
    not bool(self.slotsRoot.get == root): # TODO: `!=` doesn't work for SecretBool
      return failure "Existing slots root doesn't match reconstructed root."
  else:
    self.slotsRoot = some root

  success()

proc buildManifest*(self: SlotBuilder): Future[?!Manifest] {.async.} =
  if err =? (await self.buildSlots()).errorOption:
    error "Failed to build slot roots", err = err.msg
    return failure(err)

  without rootCids =? self.slotRoots.toSlotCids(), err:
    error "Failed to map slot roots to CIDs", err = err.msg
    return failure(err)

  without rootProvingCidRes =? self.slotsRoot.?toSlotsRootsCid() and
    rootProvingCid =? rootProvingCidRes, err: # TODO: why doesn't `=?` unpack the result?
    error "Failed to map slot roots to CIDs", err = err.msg
    return failure(err)

  Manifest.new(self.manifest, rootProvingCid, rootCids)

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
    blockPadBytes = newSeq[byte](numBlockCells.nextPowerOfTwoPad * cellSize)  # power of two padding for blocks
    numSlotLeafs = (manifest.blocksCount div manifest.numSlots)
    slotsPadLeafs = newSeqWith(numSlotLeafs.nextPowerOfTwoPad, Poseidon2Zero) # power of two padding for block roots
    rootsPadLeafs = newSeqWith(manifest.numSlots.nextPowerOfTwoPad, Poseidon2Zero)

  var
    slotsRoot: ?Poseidon2Hash
    slotRoots: seq[Poseidon2Hash]

  if manifest.verifiable:
    if manifest.slotRoots.len == 0:
      return failure "Manifest is verifiable but has no slot roots."

    slotsRoot = Poseidon2Hash.fromBytes( ( ? manifest.slotsRoot.mhash.mapFailure ).digestBytes.toArray32 )
    slotRoots = manifest.slotRoots.mapIt(
        ? Poseidon2Hash.fromBytes(
          ( ? it.mhash.mapFailure ).digestBytes.toArray32
        ).toFailure
      )

  success SlotBuilder(
    store: store,
    manifest: manifest,
    strategy: strategy,
    cellSize: cellSize,
    blockPadBytes: blockPadBytes,
    slotsPadLeafs: slotsPadLeafs,
    rootsPadLeafs: rootsPadLeafs,
    slotsRoot: slotsRoot,
    slotRoots: slotRoots)
