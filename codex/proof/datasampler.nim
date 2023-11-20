import ../contracts/requests

const
  # Size of a cell.
  # A cell is a sample of storage-data selected for proving.
  CellSize* = u256(2048)

proc getNumberOfCellsInSlot*(slot: Slot): Uint256 =
  slot.request.ask.slotSize div CellSize
