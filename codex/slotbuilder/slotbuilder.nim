import pkg/libp2p
import pkg/questionable/results
import pkg/codex/blocktype as bt
import ../blocktype
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

proc getSlotBlocks*(self: SlotBuilder, datasetSlotIndex: uint64): seq[bt.Block] =
  raiseAssert("a")

