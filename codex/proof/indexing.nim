import pkg/chronicles
import ../contracts/requests
import types

# Index naming convention:
# "<ContainerType><ElementType>Index" => The index of an ElementType within a ContainerType.
# Some examples:
# SlotBlockIndex => The index of a Block within a Slot.
# DatasetBlockIndex => The index of a Block within a Dataset.

proc getSlotBlockIndexForSlotCellIndex*(cellIndex: DSSlotCellIndex, blockSize: uint64): uint64 =
  let numberOfCellsPerBlock = blockSize div CellSize
  return cellIndex div numberOfCellsPerBlock

proc getBlockCellIndexForSlotCellIndex*(cellIndex: DSSlotCellIndex, blockSize: uint64): uint64 =
  let numberOfCellsPerBlock = blockSize div CellSize
  return cellIndex mod numberOfCellsPerBlock

proc getDatasetBlockIndexForSlotBlockIndex*(slot: Slot, blockSize: uint64, slotBlockIndex: uint64): uint64 =
  let
    slotSize = slot.request.ask.slotSize.truncate(uint64)
    blocksInSlot = slotSize div blockSize
    datasetSlotIndex = slot.slotIndex.truncate(uint64)
  return (datasetSlotIndex * blocksInSlot) + slotBlockIndex
