import pkg/libp2p
import ../blocktype
import ../stores
import ../manifest

type
  SlotBuilder* = object of RootObj
    blockStore: BlockStore
    manifest: Manifest

proc new*(
    T: type SlotBuilder,
    blockStore: BlockStore,
    manifest: Manifest
): SlotBuilder =
  SlotBuilder(
    blockStore: blockStore,
    manifest: manifest
  )

proc getSlotBlockCids*(self: SlotBuilder, datasetSlotIndex: uint64): seq[Cid] =
  raiseAssert("a")
