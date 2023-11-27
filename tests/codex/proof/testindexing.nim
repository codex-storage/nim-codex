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

