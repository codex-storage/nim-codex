import pkg/libp2p
import pkg/chronos
import pkg/chronicles
import pkg/questionable/results
import ../merkletree
import ../stores
import ../manifest

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

proc createAndSaveSlotTree*(self: SlotBuilder, datasetSlotIndex: int): Future[?!MerkleTree] {.async.} =
  without var builder =? MerkleTreeBuilder.init(), err:
    return failure(err)

  raiseAssert("not implemented")

  # select slot blocks

  # pad till cells are power of two

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
