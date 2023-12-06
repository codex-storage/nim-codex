import std/math
import pkg/libp2p
import pkg/chronos
import pkg/chronicles
import pkg/questionable/results
import ../merkletree
import ../stores
import ../manifest
import ../utils

let
  # TODO: Unified with the CellSize specified in branch "data-sampler"
  # Number of bytes in a cell. A cell is the smallest unit of data used
  # in the proving circuit.
  CellSize* = 2048

type
  SlotBuilder* = object of RootObj
    blockStore: BlockStore
    manifest: Manifest
    numberOfSlotBlocks: int

proc new*(
    T: type SlotBuilder,
    blockStore: BlockStore,
    manifest: Manifest
): ?!SlotBuilder =

  if not manifest.protected:
    return failure("Can only create SlotBuilder using protected manifests.")

  if (manifest.blocksCount mod manifest.ecK) != 0:
    return failure("Number of blocks must be divisable by number of slots.")

  if (manifest.blockSize.int mod CellSize) != 0:
    return failure("Block size must be divisable by cell size.")

  let numberOfSlotBlocks = manifest.blocksCount div manifest.ecK
  success(SlotBuilder(
    blockStore: blockStore,
    manifest: manifest,
    numberOfSlotBlocks: numberOfSlotBlocks
  ))

proc cellsPerBlock(self: SlotBuilder): int =
  self.manifest.blockSize.int div CellSize

proc getTreeLeafCid(self: SlotBuilder, datasetTreeCid: Cid, datasetBlockIndex: int): Future[?!Cid] {.async.} =
  without slotBlockCid =? await self.blockStore.getCid(datasetTreeCid, datasetBlockIndex), err:
    error "Failed to get block for tree at index", index=datasetBlockIndex, tree=datasetTreeCid
    return failure(err)

  # without slotBlockLeaf =? slotBlockCid.mhash:
  #   error "Failed to get multihash from slot block CID", slotBlockCid
  #   return failure("Failed to get multihash from slot block CID")

  return success(slotBlockCid)

proc selectSlotBlocks*(self: SlotBuilder, datasetSlotIndex: int): Future[?!seq[Cid]] {.async.} =
  var cids = newSeq[Cid]()
  let
    datasetTreeCid = self.manifest.treeCid
    blockCount = self.manifest.blocksCount
    numberOfSlots = self.manifest.ecK
    strategy = SteppedIndexingStrategy.new(0, blockCount - 1, numberOfSlots)

  for index in strategy.getIndicies(datasetSlotIndex):
    without slotBlockCid =? await self.getTreeLeafCid(datasetTreeCid, index), err:
      return failure(err)
    cids.add(slotBlockCid)

  return success(cids)

proc findNextPowerOfTwo*(i: int): int =
  # TODO: this is just a copy of the test implementation.
  # If anyone wants to try to make a faster version, plz do.
  # constantine has one in bithacks.nim 'nextPowerOfTwo_vartime'
  if i < 1:
    return 1
  let
    logtwo = log2(i.float)
    roundUp = ceil(logtwo)
    nextPow = pow(2.float, roundUp)
  return nextPow.int

proc calculateNumberOfPaddingCells*(self: SlotBuilder, numberOfSlotBlocks: int): int =
  let
    blockSize = self.manifest.blockSize.int
    expectZero = blockSize mod CellSize

  if expectZero != 0:
    raiseAssert("BlockSize should always be divisable by Cell size (2kb).")

  let
    numberOfCells = numberOfSlotBlocks * self.cellsPerBlock
    nextPowerOfTwo = findNextPowerOfTwo(numberOfCells)

  return nextPowerOfTwo - numberOfCells

proc addSlotBlocksToTreeBuilder(builder: var MerkleTreeBuilder, slotBlocks: seq[Cid]): ?!void =
  for slotBlockCid in slotBlocks:
    without leafHash =? slotBlockCid.mhash:
      error "Failed to get leaf hash from CID"
      return failure("Failed to get leaf hash from CID")

    if builder.addLeaf(leafHash).isErr:
      error "Failed to add slotBlockCid to slot tree builder"
      return failure("Failed to add slotBlockCid to slot tree builder")

  return success()

proc addPadBlocksToTreeBuilder(self: SlotBuilder, builder: var MerkleTreeBuilder, nBlocks: int): ?!void =
  without cid =? emptyCid(self.manifest.version, self.manifest.hcodec, self.manifest.codec), err:
    error "Unable to initialize empty cid"
    return failure(err)

  without emptyLeaf =? cid.mhash:
      error "Failed to get leaf hash from empty CID"
      return failure("Failed to get leaf hash from empty CID")

  for i in 0 ..< nBlocks:
    if builder.addLeaf(emptyLeaf).isErr:
      error "Failed to add empty leaf to slot tree builder"
      return failure("Failed to add empty leaf to slot tree builder")

  return success()

proc buildSlotTree*(self: SlotBuilder, slotBlocks: seq[Cid], numberOfPaddingCells: int): Future[?!MerkleTree] {.async.} =
  let numberOfPadBlocks = divUp(numberOfPaddingCells, self.cellsPerBlock)

  without var builder =? MerkleTreeBuilder.init(), err:
    error "Failed to initialize merkle tree builder"
    return failure(err)

  if addSlotBlocksToTreeBuilder(builder, slotBlocks).isErr:
    error "Failed to add slot blocks to tree builder"
    return failure("Failed to add slot blocks to tree builder")

  if self.addPadBlocksToTreeBuilder(builder, numberOfPadBlocks).isErr:
    error "Failed to add padding blocks to tree builder"
    return failure("Failed to add padding blocks to tree builder")

  without slotTree =? builder.build(), err:
    error "Failed to build slot tree"
    return failure(err)

  return success(slotTree)

proc createSlotTree*(self: SlotBuilder, datasetSlotIndex: int): Future[?!MerkleTree] {.async.} =
  without slotBlocks =? await self.selectSlotBlocks(datasetSlotIndex), err:
    error "Failed to select slot blocks"
    return failure(err)

  let numberOfPaddingCells = self.calculateNumberOfPaddingCells(slotBlocks.len)

  return await self.buildSlotTree(slotBlocks, numberOfPaddingCells)
