import pkg/chronos
import pkg/asynctest
import pkg/codex/proof/indexing
import pkg/codex/contracts/requests
import ../helpers

let
  bytesPerBlock = 64 * 1024
  numberOfSlotBlocks = 16
  blockSize = bytesPerBlock.uint64
  slot = Slot(
    request: StorageRequest(
      ask: StorageAsk(
        slots: 10,
        slotSize: u256(bytesPerBlock * numberOfSlotBlocks)
      ),
      content: StorageContent(),
    ),
    slotIndex: u256(3)
  )

checksuite "Test indexing":
  for (input, expected) in [(10, 0), (31, 0), (32, 1), (63, 1), (64, 2)]:
    test "Can get slotBlockIndex from slotCellIndex (" & $input & " -> " & $expected & ")":
      let
        slotCellIndex = input.uint64

        slotBlockIndex = getSlotBlockIndexForSlotCellIndex(slotCellIndex, blockSize)

      check:
        slotBlockIndex == expected.uint64

  for input in 0 ..< numberOfSlotBlocks:
    test "Can get datasetBlockIndex from slotBlockIndex (" & $input & ")":
      let
        slotBlockIndex = input.uint64
        datasetBlockIndex = getDatasetBlockIndexForSlotBlockIndex(slot, blockSize, slotBlockIndex)
        datasetSlotIndex = slot.slotIndex.truncate(uint64)
        expectedIndex = (numberOfSlotBlocks.uint64 * datasetSlotIndex) + slotBlockIndex

      check:
        datasetBlockIndex == expectedIndex

  for (input, expected) in [(10, 10), (31, 31), (32, 0), (63, 31), (64, 0)]:
    test "Can get blockCellIndex from slotCellIndex (" & $input & " -> " & $expected & ")":
      let
        slotCellIndex = input.uint64

        blockCellIndex = getBlockCellIndexForSlotCellIndex(slotCellIndex, blockSize)

      check:
        blockCellIndex == expected.uint64
