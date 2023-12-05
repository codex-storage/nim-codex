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
    return failure("Number of blocks must be devisable by number of slots.")

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

proc createAndSaveSlotTree*(self: SlotBuilder, datasetSlotIndex: int): Future[?!MerkleTree] {.async.} =


  raiseAssert("not implemented")

  # select slot blocks

  # pad till cells are power of two
  # -> get number of padding cells
  # -> convert to number of padding blocks

  # build tree

  # save tree

  # return tree

  # let
  #   datasetTreeCid = self.manifest.treeCid
  #   datasetBlockIndexStart = datasetSlotIndex * self.numberOfSlotBlocks
  #   datasetBlockIndexEnd = datasetBlockIndexStart + self.numberOfSlotBlocks

  # for index in datasetBlockIndexStart ..< datasetBlockIndexEnd:
  #   without slotBlockLeaf =? await self.getTreeLeafCid(datasetTreeCid, index), err:
  #     return failure(err)
  #   if builder.addLeaf(slotBlockLeaf).isErr:
  #     error "Failed to add slotBlockCid to slot tree builder"
  #     return failure("Failed to add slotBlockCid to slot tree builder")

  # without slotTree =? builder.build(), err:
  #   error "Failed to build slot tree"
  #   return failure(err)

  # if (await self.blockStore.putAllProofs(slotTree)).isErr:
  #   error "Failed to store slot tree"
  #   return failure("Failed to store slot tree")

  # return success(slotTree)

# proc createSlotManifest*(self: SlotBuilder, datasetSlotIndex: int): Future[?!Manifest] {.async.} =
#   without slotTree =? await self.createAndSaveSlotTree(datasetSlotIndex), err:
#     error "Failed to create slot tree"
#     return failure(err)

#   without slotTreeRootCid =? slotTree.rootCid, err:
#     error "Failed to get root CID from slot tree"
#     return failure(err)

#   var slotManifest = Manifest.new(
#     treeCid = slotTreeRootCid,
#     datasetSize = self.numberOfSlotBlocks.NBytes * self.manifest.blockSize,
#     blockSize = self.manifest.blockSize,
#     version = self.manifest.version,
#     hcodec = self.manifest.hcodec,
#     codec = self.manifest.codec,
#     ecK = self.manifest.ecK, # should change this = EC params of first ECing. there's be another!
#     ecM = self.manifest.ecK,
#     originalTreeCid = self.manifest.originalTreeCid,
#     originalDatasetSize = self.manifest.originalDatasetSize
#   )

#    #treeCid: Cid
#    # datasetSize: NBytes
#    # blockSize: NBytes
#    # version: CidVersion
#    # hcodec: MultiCodec
#    # codex: MultiCodec
#    # ecK: int
#    # ecM: int
#    # originalTreeCid: Cid
#    # originalDatasetSize: NBytes

# #  treeCid: Cid
# # datasetSize: NBytes
# # blockSize: NBytes
# #          version: CidVersion
# # hcodec: MultiCodec
# # codec: MultiCodec
# # ecK: int
# #          ecM: int
# # originalTreeCid: Cid
# # originalDatasetSize: NBytes): Manifest
# #   first type mismatch at position: 7



#   slotManifest.isSlot = true
#   slotManifest.datasetSlotIndex = datasetSlotIndex
#   slotManifest.originalProtectedTreeCid = self.manifest.treeCid
#   slotManifest.originalProtectedDatasetSize = self.manifest.datasetSize

#   return success(slotManifest)
